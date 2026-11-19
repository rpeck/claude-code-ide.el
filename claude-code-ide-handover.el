;;; claude-code-ide-handover.el --- Hand the work of an instance to a new conversation  -*- lexical-binding: t; -*-

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

;; A handover moves the work of one instance (the source) to a new
;; native conversation (the target), of the same provider or of the
;; other one.  The usual reason is a quota limit of the source, so the
;; source never has to run one more turn: the target gets a handover
;; document as its first prompt, and writes a state summary in its
;; first turn.
;;
;; The steps, each saved in the session registry before it runs:
;;
;;   requested -> quiescing -> source-stopped -> document-written
;;   -> target-started -> target-identified -> delivered -> committed
;;
;; The handover runs from timers and events, so Emacs never waits for
;; it.  `claude-code-ide-handover-session' starts one and returns at
;; once; `claude-code-ide-handover-status' gives its progress.  After a
;; crash, `claude-code-ide-handover-recover' continues it: before the
;; stop it is cancelled, after the stop its target is resumed or
;; started again, and the source never runs again.
;;
;; docs/handover.md describes the operation, the stages, the recovery
;; and the commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-control)
(require 'claude-code-ide-process nil t)
(require 'claude-code-ide-transcript nil t)

(declare-function claude-code-ide-process-stop-later "claude-code-ide-process" (instance &rest args))
(declare-function claude-code-ide-process-worktree-strays "claude-code-ide-process" (worktree &optional exclude))
(declare-function claude-code-ide-transcript-handover-document "claude-code-ide-transcript" (&rest args))
(declare-function claude-code-ide-transcript-instance-leg "claude-code-ide-transcript" (instance))
(declare-function claude-code-ide-transcript-document-id "claude-code-ide-transcript" (text))
(declare-function claude-code-ide-transcript-read "claude-code-ide-transcript" (file &optional format root))
(declare-function claude-code-ide-mcp-request-instance-id "claude-code-ide-mcp-server" ())

(defvar claude-code-ide-session-registry-mode)

(defgroup claude-code-ide-handover nil
  "Hand the work of an instance to a new conversation."
  :group 'claude-code-ide
  :prefix "claude-code-ide-handover-")

(defcustom claude-code-ide-handover-quiesce-timeout 600
  "Seconds that a handover waits for its source to become idle.
After this time the handover is cancelled, and the source stays the
current instance."
  :type 'number
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-poll-interval 1
  "Seconds between two checks of the state of the source while it quiesces."
  :type 'number
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-stray-wait 10
  "Seconds to wait before the worktree is scanned again for stray processes.
The choices \"wait\" and \"end them\" of a handover with strays use it."
  :type 'number
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-directory ".handover"
  "Folder in the worktree for the handover documents and state summaries.
The handover adds it to the Git exclude file of the worktree."
  :type 'string
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-session-server-detection 'auto
  "Whether the handover document refers the target to the session server.
`auto' reads the configuration of the target provider (see
`claude-code-ide-transcript-session-server-p'), t always refers to the
server, and nil never does.  The server itself is
`claude-code-ide-handover-session-server'."
  :type '(choice (const :tag "Read the configuration" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-budget nil
  "Size budget of the handover document in characters.
nil uses `claude-code-ide-transcript-budget'."
  :type '(choice (const :tag "The transcript default" nil) integer)
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-recover-at-start nil
  "When non-nil, continue interrupted handovers when the registry starts.
A handover that a crash cut off before its source stopped is always
cancelled at that time; that only changes the registry.  A later one
starts a CLI, so by default it waits for `claude-code-ide-restore-sessions'
or `claude-code-ide-handover-recover'."
  :type 'boolean
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-enable-request-tool t
  "When non-nil, give the agents the MCP tool request_handover.
The tool only saves a request.  After the next turn end of the agent,
Emacs asks you whether to hand over."
  :type 'boolean
  :group 'claude-code-ide-handover)

(defconst claude-code-ide-handover-stages
  '(requested quiescing source-stopped document-written
              target-started target-identified delivered committed)
  "The stages of a handover, in order.")

;;; Runs

(cl-defstruct (claude-code-ide-handover--run
               (:constructor claude-code-ide-handover--run-create)
               (:copier nil))
  "One handover that this Emacs runs or recovers."
  (id nil :type string :documentation "Handover ID.")
  (request-id nil :documentation "Request ID that the caller gave, or nil.")
  (source-id nil :type string :documentation "Instance ID of the source.")
  (source-provider nil :documentation "Provider of the source.")
  (target-provider nil :documentation "Provider of the target.")
  (target-id nil :documentation "Instance ID of the target, once chosen.")
  (target-native-id nil :documentation "Native ID of the target, once known.")
  (method 'fresh :documentation "`fresh' or `fork'.")
  (fork-id nil :documentation "Native ID that a fork starts from.")
  (context nil :documentation "Text of the coordinator, or nil.")
  (interrupt nil :documentation "Non-nil to interrupt a busy source.")
  (force nil :documentation "Non-nil to go on while subagents or tasks run.")
  (interactive nil :documentation "Non-nil when a person started it in Emacs.")
  (stage 'requested :documentation "The stage that the run is in.")
  (status 'running :documentation "`running', `needs-user', `committed', `cancelled' or `failed'.")
  (reason nil :documentation "Symbol that says why the status is what it is.")
  (message nil :documentation "Text for people, or nil.")
  (strays nil :documentation "Stray processes of the stop, as plists.")
  (worktree nil :documentation "Working tree of the source.")
  (directory nil :documentation "Project directory of the source.")
  (instance-name nil :documentation "Instance name of the source.")
  (role nil :documentation "Role of the source.")
  (source-leg nil :documentation "Leg plist of the source, from the quiescing.")
  (chain nil :documentation "Legs of the chain of the source, oldest first.")
  (document nil :documentation "File of the handover document.")
  (document-hash nil :documentation "SHA-256 of the document.")
  (summary-file nil :documentation "State summary file of the target.")
  (interrupted nil :documentation "Non-nil after the interrupt was sent.")
  (deadline nil :documentation "Float time when the quiescing gives up.")
  (timer nil :documentation "The timer of the next step, or nil.")
  (created-at nil)
  (updated-at nil))

(defvar claude-code-ide-handover--runs (make-hash-table :test 'equal)
  "The handovers of this Emacs, by handover ID.")

(defvar claude-code-ide-handover--allowed nil
  "ID of the handover whose own start may run in its worktree.
`claude-code-ide-handover--guard-start' lets only this start through
while a handover holds the worktree.")

(defun claude-code-ide-handover--now ()
  "Return the current time as an ISO 8601 string in UTC."
  (format-time-string "%FT%TZ" nil t))

(defun claude-code-ide-handover--unfinished-p (run)
  "Return non-nil when RUN is neither committed nor ended."
  (memq (claude-code-ide-handover--run-status run) '(running needs-user)))

(defun claude-code-ide-handover--stage-index (stage)
  "Return the position of STAGE in `claude-code-ide-handover-stages'."
  (or (cl-position stage claude-code-ide-handover-stages) -1))

(defun claude-code-ide-handover--stage< (a b)
  "Return non-nil when the stage A comes before the stage B."
  (< (claude-code-ide-handover--stage-index a) (claude-code-ide-handover--stage-index b)))

;;; The registry record

(defun claude-code-ide-handover--name (value)
  "Return VALUE as a string for the registry: a symbol gives its name."
  (if (and value (symbolp value) (not (eq value t))) (symbol-name value) value))

(defun claude-code-ide-handover--symbol (value)
  "Return the string VALUE of the registry as a symbol, or nil."
  (and (stringp value) (not (string-empty-p value)) (intern value)))

(defun claude-code-ide-handover--stray-to-alist (stray)
  "Return the STRAY plist as an alist for the registry."
  (list (cons 'pid (plist-get stray :pid))
        (cons 'command (plist-get stray :command))
        (cons 'cwd (plist-get stray :cwd))
        (cons 'reason (claude-code-ide-handover--name (plist-get stray :reason)))))

(defun claude-code-ide-handover--stray-from-alist (alist)
  "Return the stray plist of the registry ALIST."
  (list :pid (alist-get 'pid alist)
        :command (alist-get 'command alist)
        :cwd (alist-get 'cwd alist)
        :reason (claude-code-ide-handover--symbol (alist-get 'reason alist))))

(defun claude-code-ide-handover--to-alist (run)
  "Return the registry record of RUN, an alist with JSON keys."
  (let ((leg (claude-code-ide-handover--run-source-leg run)))
    (delq nil
          (list
           (cons 'id (claude-code-ide-handover--run-id run))
           (cons 'request_id (claude-code-ide-handover--run-request-id run))
           (cons 'stage (claude-code-ide-handover--name (claude-code-ide-handover--run-stage run)))
           (cons 'status (claude-code-ide-handover--name (claude-code-ide-handover--run-status run)))
           (cons 'reason (claude-code-ide-handover--name (claude-code-ide-handover--run-reason run)))
           (cons 'message (claude-code-ide-handover--run-message run))
           (cons 'method (claude-code-ide-handover--name (claude-code-ide-handover--run-method run)))
           (cons 'fork_id (claude-code-ide-handover--run-fork-id run))
           (cons 'source_instance_id (claude-code-ide-handover--run-source-id run))
           (cons 'source_provider (claude-code-ide-handover--name
                                   (claude-code-ide-handover--run-source-provider run)))
           (cons 'target_provider (claude-code-ide-handover--name
                                   (claude-code-ide-handover--run-target-provider run)))
           (cons 'target_instance_id (claude-code-ide-handover--run-target-id run))
           (cons 'target_native_id (claude-code-ide-handover--run-target-native-id run))
           (cons 'worktree (claude-code-ide-handover--run-worktree run))
           (cons 'directory (claude-code-ide-handover--run-directory run))
           (cons 'instance_name (claude-code-ide-handover--run-instance-name run))
           (cons 'role (claude-code-ide-handover--run-role run))
           (cons 'document (claude-code-ide-handover--run-document run))
           (cons 'document_hash (claude-code-ide-handover--run-document-hash run))
           (cons 'summary_file (claude-code-ide-handover--run-summary-file run))
           (when leg
             (cons 'source_leg (claude-code-ide-session-registry-leg-to-alist leg)))
           (when (claude-code-ide-handover--run-strays run)
             (cons 'strays (vconcat (mapcar #'claude-code-ide-handover--stray-to-alist
                                            (claude-code-ide-handover--run-strays run)))))
           (cons 'interactive (and (claude-code-ide-handover--run-interactive run) t))
           (cons 'emacs_pid (emacs-pid))
           (cons 'host (system-name))
           (cons 'created_at (claude-code-ide-handover--run-created-at run))
           (cons 'updated_at (claude-code-ide-handover--run-updated-at run))))))

(defun claude-code-ide-handover--from-alist (alist entry)
  "Return the run of the registry record ALIST of the source ENTRY."
  (let ((leg (alist-get 'source_leg alist)))
    (claude-code-ide-handover--run-create
     :id (alist-get 'id alist)
     :request-id (alist-get 'request_id alist)
     :source-id (or (alist-get 'source_instance_id alist)
                    (claude-code-ide-session-registry-entry-key entry))
     :source-provider (or (claude-code-ide-handover--symbol (alist-get 'source_provider alist))
                          (claude-code-ide-session-registry-entry-provider entry))
     :target-provider (claude-code-ide-handover--symbol (alist-get 'target_provider alist))
     :target-id (alist-get 'target_instance_id alist)
     :target-native-id (alist-get 'target_native_id alist)
     :method (or (claude-code-ide-handover--symbol (alist-get 'method alist)) 'fresh)
     :fork-id (alist-get 'fork_id alist)
     :stage (or (claude-code-ide-handover--symbol (alist-get 'stage alist)) 'requested)
     :status (or (claude-code-ide-handover--symbol (alist-get 'status alist)) 'running)
     :reason (claude-code-ide-handover--symbol (alist-get 'reason alist))
     :message (alist-get 'message alist)
     :worktree (alist-get 'worktree alist)
     :directory (or (alist-get 'directory alist)
                    (claude-code-ide-session-registry-entry-project-dir entry))
     :instance-name (alist-get 'instance_name alist)
     :role (alist-get 'role alist)
     :document (alist-get 'document alist)
     :document-hash (alist-get 'document_hash alist)
     :summary-file (alist-get 'summary_file alist)
     :source-leg (and (consp leg) (claude-code-ide-session-registry-leg-from-alist leg))
     :chain (claude-code-ide-session-registry-entry-legs entry)
     :strays (mapcar #'claude-code-ide-handover--stray-from-alist (alist-get 'strays alist))
     :interactive (alist-get 'interactive alist)
     :created-at (alist-get 'created_at alist)
     :updated-at (alist-get 'updated_at alist))))

(defun claude-code-ide-handover--save (run)
  "Save RUN in the registry entry of its source.  Return non-nil when saved."
  (setf (claude-code-ide-handover--run-updated-at run) (claude-code-ide-handover--now))
  (claude-code-ide-session-registry-save-handover
   (claude-code-ide-handover--run-source-id run)
   (claude-code-ide-handover--to-alist run)))

;;; Results

(defun claude-code-ide-handover--error (reason &optional message instance-id)
  "Return the error result with REASON, MESSAGE and INSTANCE-ID."
  (append (list :status 'error :reason reason)
          (when instance-id (list :instance-id instance-id))
          (when message (list :message message))))

(defun claude-code-ide-handover--result (run &optional duplicate)
  "Return the result plist of RUN.  DUPLICATE non-nil adds :duplicate t."
  (append
   (list :status (claude-code-ide-handover--run-status run)
         :handover-id (claude-code-ide-handover--run-id run)
         :request-id (claude-code-ide-handover--run-request-id run)
         :stage (claude-code-ide-handover--run-stage run)
         :source-id (claude-code-ide-handover--run-source-id run)
         :target-id (claude-code-ide-handover--run-target-id run)
         :target-provider (claude-code-ide-handover--run-target-provider run)
         :method (claude-code-ide-handover--run-method run)
         :reason (claude-code-ide-handover--run-reason run)
         :message (claude-code-ide-handover--run-message run)
         :document (claude-code-ide-handover--run-document run)
         :document-hash (claude-code-ide-handover--run-document-hash run)
         :strays (mapcar (lambda (stray)
                           (list :pid (plist-get stray :pid)
                                 :command (plist-get stray :command)
                                 :cwd (plist-get stray :cwd)
                                 :reason (plist-get stray :reason)))
                         (claude-code-ide-handover--run-strays run)))
   (when duplicate (list :duplicate t))))

(defun claude-code-ide-handover--registry-runs ()
  "Return the runs of all handovers in the registry, with their records."
  (when (bound-and-true-p claude-code-ide-session-registry-mode)
    (delq nil
          (mapcar (lambda (entry)
                    (when-let* ((alist (claude-code-ide-session-registry-entry-handover entry)))
                      (claude-code-ide-handover--from-alist alist entry)))
                  (ignore-errors (claude-code-ide-session-registry--entries))))))

(defun claude-code-ide-handover--find (id)
  "Return the run whose handover ID or request ID is ID, or nil.
The runs of this Emacs come first, then the registry."
  (when (stringp id)
    (let ((match (lambda (run)
                   (or (equal (claude-code-ide-handover--run-id run) id)
                       (equal (claude-code-ide-handover--run-request-id run) id)))))
      (or (gethash id claude-code-ide-handover--runs)
          (cl-find-if match (hash-table-values claude-code-ide-handover--runs))
          (cl-find-if match (claude-code-ide-handover--registry-runs))))))

(defun claude-code-ide-handover-status (id)
  "Return the result of the handover whose handover ID or request ID is ID.
The result has :status (`running', `needs-user', `committed',
`cancelled' or `failed'), :handover-id, :stage, :source-id, :target-id,
:reason, :message and :strays.  An unknown ID gives (:status error
:reason unknown-handover)."
  (if-let* ((run (claude-code-ide-handover--find id)))
      (claude-code-ide-handover--result run)
    (claude-code-ide-handover--error 'unknown-handover nil)))

;;; Worktrees and the one writer rule

(defun claude-code-ide-handover--directory-key (directory)
  "Return the working tree of DIRECTORY, or DIRECTORY itself, as a folder name."
  (when (stringp directory)
    (let ((root (claude-code-ide--worktree-root directory)))
      (file-name-as-directory
       (expand-file-name (if (stringp root) root directory))))))

(defun claude-code-ide-handover--holding-run (directory)
  "Return the unfinished handover that holds the working tree of DIRECTORY, or nil.
The handovers of this Emacs and the unfinished handovers in the
registry (for example of an Emacs that crashed) count."
  (when-let* ((key (claude-code-ide-handover--directory-key directory)))
    (cl-find-if (lambda (run)
                  (and (claude-code-ide-handover--unfinished-p run)
                       (equal (claude-code-ide-handover--directory-key
                               (or (claude-code-ide-handover--run-worktree run)
                                   (claude-code-ide-handover--run-directory run)))
                              key)))
                (append (hash-table-values claude-code-ide-handover--runs)
                        (claude-code-ide-handover--registry-runs)))))

(defun claude-code-ide-handover--guard-start (start &optional continue resume spec)
  "Refuse a start in a working tree that a handover holds, then call START.
START is `claude-code-ide--start-session', and CONTINUE, RESUME and
SPEC its arguments.  Only the start of the handover's own target, in
`claude-code-ide-handover--allowed', goes through: one writer for each
working tree."
  (let* ((directory (ignore-errors
                      (if spec
                          (claude-code-ide-start-spec-directory spec)
                        (claude-code-ide--get-working-directory))))
         (run (and directory (claude-code-ide-handover--holding-run directory))))
    (when (and run (not (equal claude-code-ide-handover--allowed
                               (claude-code-ide-handover--run-id run))))
      (user-error "Handover %s holds %s (stage %s); no other instance can start there until it ends"
                  (claude-code-ide-handover--run-id run)
                  (claude-code-ide-handover--directory-key directory)
                  (claude-code-ide-handover--run-stage run)))
    (funcall start continue resume spec)))

(advice-add 'claude-code-ide--start-session :around #'claude-code-ide-handover--guard-start)

;;; Helpers for the source

(defun claude-code-ide-handover--event-value (data key)
  "Return the value of KEY, a string, in the hook DATA, or nil."
  (cond
   ((and (consp data) (keywordp (car data)))
    (plist-get data (intern (concat ":" key))))
   ((consp data)
    (cdr (or (assq (intern key) data) (assoc key data))))))

(defun claude-code-ide-handover--codex-home ()
  "Return the Codex home folder."
  (file-name-as-directory
   (or (and (getenv "CODEX_HOME") (not (string-empty-p (getenv "CODEX_HOME")))
            (getenv "CODEX_HOME"))
       (expand-file-name ".codex" "~"))))

(defun claude-code-ide-handover--codex-rollout (native-id)
  "Return the Codex rollout file of the conversation NATIVE-ID, or nil.
The Codex provider has no transcript operation, so this searches the
sessions folder of the Codex home."
  (when (and (stringp native-id) (string-match-p "\\`[0-9A-Za-z-]+\\'" native-id))
    (let ((dir (expand-file-name "sessions" (claude-code-ide-handover--codex-home))))
      (when (file-directory-p dir)
        (car (last (sort (directory-files-recursively
                          dir (concat "\\`rollout-.*" (regexp-quote native-id) "\\.jsonl\\'"))
                         #'string<)))))))

(defun claude-code-ide-handover--transcript-file (provider native-id &optional entry leg)
  "Return the transcript file of the conversation NATIVE-ID of PROVIDER, or nil.
It is the :transcript of LEG, else the transcript path of the registry
ENTRY, else for Codex the rollout file of NATIVE-ID."
  (let ((candidates (list (plist-get leg :transcript)
                          (and entry (claude-code-ide-session-registry-entry-transcript-path entry)))))
    (or (cl-find-if (lambda (file) (and (stringp file) (file-readable-p file))) candidates)
        (and (eq provider 'codex) (claude-code-ide-handover--codex-rollout native-id)))))

(defun claude-code-ide-handover--line-count (file)
  "Return the number of lines of FILE, or nil when it cannot be read."
  (when (and (stringp file) (file-readable-p file))
    (or (ignore-errors
          (with-temp-buffer
            (when (eql 0 (call-process "wc" nil t nil "-l" (expand-file-name file)))
              (let ((count (car (split-string (buffer-string)))))
                (and count (string-match-p "\\`[0-9]+\\'" count) (string-to-number count))))))
        (with-temp-buffer
          (insert-file-contents-literally file)
          (count-lines (point-min) (point-max))))))

(defun claude-code-ide-handover--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return its trimmed output, or nil."
  (ignore-errors
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory))
            (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment)))
        (when (eql 0 (apply #'process-file "git" nil t nil args))
          (string-trim (buffer-string)))))))

(defun claude-code-ide-handover--chain-of (instance-id)
  "Return the legs of the chain of INSTANCE-ID from the registry, oldest first."
  (when-let* ((entry (claude-code-ide-session-registry-entry-of instance-id)))
    (claude-code-ide-session-registry-entry-legs entry)))

(defun claude-code-ide-handover--fork-id (chain source-leg provider)
  "Return the newest native ID of PROVIDER among CHAIN and SOURCE-LEG, or nil.
A fork starts from the latest conversation of the target provider in
the chain; the source counts when it has that provider."
  (cl-some (lambda (leg)
             (and (eq (plist-get leg :provider) provider)
                  (stringp (plist-get leg :native-id))
                  (plist-get leg :native-id)))
           (reverse (append chain (and source-leg (list source-leg))))))

(defun claude-code-ide-handover--source-leg (instance)
  "Return the leg plist of the conversation of the source INSTANCE now."
  (let* ((id (claude-code-ide-instance-id instance))
         (entry (claude-code-ide-session-registry-entry-of id))
         (leg (if (fboundp 'claude-code-ide-transcript-instance-leg)
                  (claude-code-ide-transcript-instance-leg instance)
                (list :provider (claude-code-ide-instance-provider instance)
                      :instance-id id
                      :native-id (claude-code-ide-known-or-nil
                                  (claude-code-ide-instance-native-id instance)))))
         (own (car (last (claude-code-ide-handover--chain-of id)))))
    (unless (plist-get leg :transcript)
      (setq leg (plist-put leg :transcript
                           (claude-code-ide-handover--transcript-file
                            (plist-get leg :provider) (plist-get leg :native-id) entry))))
    ;; The record of the handover that started the source fills in its
    ;; handover ID, document hash, summary file and start commit
    (when (and own (equal (plist-get own :instance-id) id))
      (cl-loop for (key value) on own by #'cddr
               unless (or (plist-get leg key) (eq key :pending))
               do (setq leg (plist-put leg key value))))
    leg))

;;; Starting a handover

(defun claude-code-ide-handover--busy-state-p (state)
  "Return non-nil when STATE says that subagents or background tasks run."
  (eq (plist-get state :state) 'waiting-for-task))

(defun claude-code-ide-handover--quiet-state-p (state)
  "Return non-nil when STATE lets the handover stop the source now.
That is idle, failed (for example at a quota limit), or waiting for an
answer to a question at the end of its turn."
  (or (memq (plist-get state :state) '(idle failed))
      (and (eq (plist-get state :state) 'waiting-for-user)
           (eq (plist-get state :reason) 'question))))

(defun claude-code-ide-handover--missing-feature ()
  "Return the name of a function that a handover needs and that is missing."
  (cl-find-if-not #'fboundp '(claude-code-ide-process-stop-later
                              claude-code-ide-process-worktree-strays
                              claude-code-ide-transcript-handover-document)))

(cl-defun claude-code-ide-handover-session (instance-id target-provider
                                                        &key (method 'fresh) context interrupt
                                                        force request-id interactive)
  "Hand the work of INSTANCE-ID to a new conversation of TARGET-PROVIDER.
TARGET-PROVIDER is a provider name, such as `codex'.  The keys:

- METHOD: `fresh' (the default) starts a new conversation with the
  handover document as its first prompt.  `fork' forks the latest
  conversation of TARGET-PROVIDER in the chain, and gives it the
  document.
- CONTEXT: text of the coordinator for the document, or nil.
- INTERRUPT: non-nil to interrupt the source when it is busy.  Without
  it, the handover waits until the source is idle.
- FORCE: non-nil to go on while subagents or background tasks run.
- REQUEST-ID: a string that the caller chooses.  A second call with a
  known request ID returns the current result of the first one, with
  :duplicate t, and starts nothing.
- INTERACTIVE: non-nil when a person asks in Emacs; then Emacs asks
  that person about stray processes.  A coordinator call gets the
  status `needs-user' instead.

The handover runs from timers and returns at once.  The result is the
plist of `claude-code-ide-handover-status', or an error result
\(:status error :reason REASON :message TEXT)."
  (let* ((request-id (cond ((stringp request-id) request-id)
                           ((numberp request-id) (number-to-string request-id))))
         (known (and request-id (claude-code-ide-handover--find request-id)))
         (method (if (stringp method) (intern method) (or method 'fresh)))
         (target-provider (if (stringp target-provider) (intern target-provider) target-provider))
         (instance (claude-code-ide-instance-by-id instance-id))
         (missing (claude-code-ide-handover--missing-feature)))
    (cond
     (known (claude-code-ide-handover--result known t))
     (missing
      (claude-code-ide-handover--error
       'unavailable (format "The handover needs %s" missing) instance-id))
     ((not (bound-and-true-p claude-code-ide-session-registry-mode))
      (claude-code-ide-handover--error
       'registry-off "A handover saves its stages in the session registry: turn on claude-code-ide-session-registry-mode"
       instance-id))
     ((not (and instance (claude-code-ide-instance-live-p instance)))
      (claude-code-ide-handover--error 'not-running nil instance-id))
     ((not (memq method '(fresh fork)))
      (claude-code-ide-handover--error
       'invalid-method (format "Unknown method %s; use fresh or fork" method) instance-id))
     ((not (and target-provider (claude-code-ide-get-provider target-provider)))
      (claude-code-ide-handover--error
       'unknown-provider (format "No provider named %s" target-provider) instance-id))
     ((claude-code-ide-unknown-p
       (claude-code-ide-provider-call (claude-code-ide-instance-provider instance)
                                      'native-id instance))
      (claude-code-ide-handover--error
       'no-conversation "The source has no conversation yet, so there is nothing to hand over"
       instance-id))
     ((null (claude-code-ide-session-registry-entry-of instance-id))
      (claude-code-ide-handover--error
       'no-registry-entry "The session registry has no entry of the source" instance-id))
     ((when-let* ((run (claude-code-ide-handover--holding-run
                        (claude-code-ide-known-or-nil
                         (claude-code-ide-instance-project-root instance)))))
        (claude-code-ide-handover--error
         'handover-running
         (format "Handover %s holds this working tree" (claude-code-ide-handover--run-id run))
         instance-id)))
     ((and (not force)
           (claude-code-ide-handover--busy-state-p (claude-code-ide-instance-state instance)))
      (claude-code-ide-handover--error
       'busy "Subagents or background tasks run in the source; give :force to hand over anyway"
       instance-id))
     (t
      (let* ((chain (claude-code-ide-handover--chain-of instance-id))
             (fork-id (and (eq method 'fork)
                           (claude-code-ide-handover--fork-id
                            chain (claude-code-ide-handover--source-leg instance) target-provider))))
        (cond
         ((and (eq method 'fork) (not fork-id))
          (claude-code-ide-handover--error
           'no-earlier-conversation
           (format "The chain has no conversation of %s to fork" target-provider) instance-id))
         ((and (eq method 'fork)
               (not (claude-code-ide-provider-supports-p
                     (claude-code-ide-get-provider target-provider) 'fork)))
          (claude-code-ide-handover--error
           'unavailable (format "The %s provider cannot fork" target-provider) instance-id))
         (t
          (claude-code-ide-handover--begin
           instance target-provider method fork-id context interrupt force request-id
           interactive chain))))))))

(defun claude-code-ide-handover--begin (instance target-provider method fork-id context
                                                 interrupt force request-id interactive chain)
  "Create and save the run of a handover of INSTANCE, and schedule its first step.
TARGET-PROVIDER, METHOD, FORK-ID, CONTEXT, INTERRUPT, FORCE,
REQUEST-ID, INTERACTIVE and CHAIN are as for
`claude-code-ide-handover-session'.  Return the result."
  (let* ((session (claude-code-ide-instance-session instance))
         (directory (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))
         (run (claude-code-ide-handover--run-create
               :id (claude-code-ide-instance-new-id)
               :request-id request-id
               :source-id (claude-code-ide-instance-id instance)
               :source-provider (claude-code-ide-instance-provider instance)
               :target-provider target-provider
               :method method
               :fork-id fork-id
               :context context
               :interrupt interrupt
               :force force
               :interactive interactive
               :worktree (claude-code-ide-handover--directory-key directory)
               :directory directory
               :instance-name (and session (claude-code-ide-mcp-session-instance-name session))
               :role (claude-code-ide-instance-role instance)
               :chain chain
               :created-at (claude-code-ide-handover--now))))
    (if (not (claude-code-ide-handover--save run))
        (claude-code-ide-handover--error
         'registry-write-failed "The session registry could not save the handover"
         (claude-code-ide-instance-id instance))
      (puthash (claude-code-ide-handover--run-id run) run claude-code-ide-handover--runs)
      (claude-code-ide-handover--schedule run 0)
      (claude-code-ide-handover--result run))))

;;; Steps

(defun claude-code-ide-handover--schedule (run seconds)
  "Run the next step of RUN after SECONDS."
  (when (timerp (claude-code-ide-handover--run-timer run))
    (cancel-timer (claude-code-ide-handover--run-timer run)))
  (setf (claude-code-ide-handover--run-timer run)
        (run-at-time seconds nil #'claude-code-ide-handover--step run)))

(defun claude-code-ide-handover--enter (run stage)
  "Move RUN to STAGE and save it before the step of STAGE runs.
Return non-nil when the registry holds the stage.  When it does not,
the step waits and is tried again."
  (setf (claude-code-ide-handover--run-stage run) stage)
  (or (claude-code-ide-handover--save run)
      (progn
        (message "Handover %s: the registry is busy; trying again"
                 (claude-code-ide-handover--run-id run))
        (claude-code-ide-handover--schedule run 1)
        nil)))

(defun claude-code-ide-handover--finish (run status reason &optional text)
  "End RUN with STATUS, REASON and TEXT, save it, and tell the user."
  (when (timerp (claude-code-ide-handover--run-timer run))
    (cancel-timer (claude-code-ide-handover--run-timer run)))
  (setf (claude-code-ide-handover--run-status run) status
        (claude-code-ide-handover--run-reason run) reason
        (claude-code-ide-handover--run-message run) text
        (claude-code-ide-handover--run-timer run) nil)
  (claude-code-ide-handover--save run)
  (message "Handover %s %s%s" (claude-code-ide-handover--run-id run) status
           (if text (concat ": " text) "")))

(defun claude-code-ide-handover--step (run)
  "Run the step of the current stage of RUN.
An error in a step gives the status `needs-user', so that a person
can try again or cancel."
  (setf (claude-code-ide-handover--run-timer run) nil)
  (when (eq (claude-code-ide-handover--run-status run) 'running)
    (condition-case err
        (pcase (claude-code-ide-handover--run-stage run)
          ('requested
           (when (claude-code-ide-handover--enter run 'quiescing)
             (claude-code-ide-handover--quiesce run)))
          ('quiescing (claude-code-ide-handover--quiesce run))
          ('source-stopped (claude-code-ide-handover--stop run))
          ('document-written (claude-code-ide-handover--write-document run))
          ('target-started (claude-code-ide-handover--start-target run))
          (_ nil))
      (error
       (claude-code-ide-handover--needs-user
        run 'step-failed
        (format "Stage %s failed: %s" (claude-code-ide-handover--run-stage run)
                (error-message-string err)))))))

;;; Quiescing

(defun claude-code-ide-handover--interrupt (instance)
  "Send the interrupt key (Escape) to the terminal of INSTANCE."
  (when-let* ((buffer (claude-code-ide-instance-buffer instance))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (claude-code-ide--terminal-send-escape))
    t))

(defun claude-code-ide-handover--quiesce (run)
  "Wait until the source of RUN is quiet, then go to the stop.
With the interrupt key, interrupt a busy source one time.  Subagents
or background tasks cancel the handover, unless it is forced.  After
`claude-code-ide-handover-quiesce-timeout' the handover is cancelled,
and the source stays current."
  (let* ((instance (claude-code-ide-instance-by-id (claude-code-ide-handover--run-source-id run)))
         (live (and instance (claude-code-ide-instance-live-p instance)))
         (state (and live (claude-code-ide-instance-state instance))))
    (unless (claude-code-ide-handover--run-deadline run)
      (setf (claude-code-ide-handover--run-deadline run)
            (+ (float-time) claude-code-ide-handover-quiesce-timeout)))
    (cond
     ;; The source ended by itself, or it is quiet, or it is forced
     ((or (not live)
          (claude-code-ide-handover--quiet-state-p state)
          (and (claude-code-ide-handover--run-force run)
               (claude-code-ide-handover--busy-state-p state)))
      (when instance
        (setf (claude-code-ide-handover--run-source-leg run)
              (claude-code-ide-handover--source-leg instance)))
      (when (claude-code-ide-handover--enter run 'source-stopped)
        (claude-code-ide-handover--stop run)))
     ((claude-code-ide-handover--busy-state-p state)
      (claude-code-ide-handover--finish
       run 'cancelled 'busy "Subagents or background tasks run in the source; it stays current"))
     ((> (float-time) (claude-code-ide-handover--run-deadline run))
      (claude-code-ide-handover--finish
       run 'cancelled 'not-idle
       (format "The source did not become idle in %s seconds; it stays current"
               claude-code-ide-handover-quiesce-timeout)))
     (t
      (when (and (claude-code-ide-handover--run-interrupt run)
                 (not (claude-code-ide-handover--run-interrupted run)))
        (setf (claude-code-ide-handover--run-interrupted run) t)
        (claude-code-ide-handover--interrupt instance))
      (claude-code-ide-handover--schedule run claude-code-ide-handover-poll-interval)))))

;;; The stop

(defun claude-code-ide-handover--relevant-strays (strays)
  "Return the STRAYS that can still write in the worktree.
A process that this Emacs runs itself (`:emacs-process', for example a
language server or a shell buffer) is not a writer of the source."
  (cl-remove-if (lambda (stray) (plist-get stray :emacs-process)) strays))

(defun claude-code-ide-handover--stop (run)
  "End the source of RUN with its process tree, then check the worktree."
  (let ((instance (claude-code-ide-instance-by-id (claude-code-ide-handover--run-source-id run))))
    (if (and instance (claude-code-ide-instance-live-p instance))
        (claude-code-ide-process-stop-later
         instance
         ;; nil: the soft end of the provider
         :soft-end nil
         :worktree (claude-code-ide-handover--run-worktree run)
         :callback (lambda (result) (claude-code-ide-handover--after-stop run result)))
      (claude-code-ide-handover--after-stop run (claude-code-ide-handover--scan run)))))

(defun claude-code-ide-handover--scan (run)
  "Scan the worktree of RUN for stray processes.
Return a result plist like that of `claude-code-ide-process-stop'."
  (condition-case err
      (let ((strays (claude-code-ide-process-worktree-strays
                     (claude-code-ide-handover--run-worktree run))))
        (list :status (if strays 'strays 'stopped) :strays strays))
    (error (list :status 'error :reason (error-message-string err)))))

(defun claude-code-ide-handover--after-stop (run result)
  "Go on with RUN after the stop or the scan that gave RESULT.
Strays, a source that survived, and a failed scan need a person."
  (when (eq (claude-code-ide-handover--run-status run) 'running)
    (let ((strays (claude-code-ide-handover--relevant-strays (plist-get result :strays))))
      (pcase (plist-get result :status)
        ((or 'stopped (and 'strays (guard (null strays))))
         (claude-code-ide-handover--source-stopped run))
        ('strays
         (claude-code-ide-handover--needs-user
          run 'strays "Processes still run in the worktree" strays))
        ('timeout
         (claude-code-ide-handover--needs-user
          run 'source-did-not-stop "The source or its processes survived SIGKILL" strays))
        (_
         (claude-code-ide-handover--needs-user
          run 'scan-failed (format "The process check failed: %s" (plist-get result :reason))))))))

(defun claude-code-ide-handover--source-stopped (run)
  "Record where the source transcript of RUN ended, and write the document."
  (setf (claude-code-ide-handover--run-strays run) nil
        (claude-code-ide-handover--run-reason run) nil
        (claude-code-ide-handover--run-message run) nil)
  (let* ((leg (claude-code-ide-handover--run-source-leg run))
         (lines (claude-code-ide-handover--line-count (plist-get leg :transcript))))
    (when lines
      (setf (claude-code-ide-handover--run-source-leg run) (plist-put leg :end-record lines))))
  (when (claude-code-ide-handover--enter run 'document-written)
    (claude-code-ide-handover--write-document run)))

;;; Needs user

(defun claude-code-ide-handover--needs-user (run reason text &optional strays)
  "Stop RUN for a person: REASON, TEXT and STRAYS say why.
A handover that a person started asks that person at once.  Else the
coordinator sees the status `needs-user', and Emacs shows a message."
  (setf (claude-code-ide-handover--run-status run) 'needs-user
        (claude-code-ide-handover--run-reason run) reason
        (claude-code-ide-handover--run-message run) text
        (claude-code-ide-handover--run-strays run) strays)
  (claude-code-ide-handover--save run)
  (if (claude-code-ide-handover--run-interactive run)
      (run-at-time 0 nil #'claude-code-ide-handover--ask run)
    (message "Handover %s needs you: %s.  M-x claude-code-ide-handover-resolve"
             (claude-code-ide-handover--run-id run) text)))

(defun claude-code-ide-handover--choices (run)
  "Return the choices of a person for RUN, as (KEY ACTION DESCRIPTION)."
  (pcase (claude-code-ide-handover--run-reason run)
    ((or 'strays 'source-did-not-stop)
     '((?e end "end them: SIGTERM, then SIGKILL")
       (?w wait "wait, then check again")
       (?c cancel "cancel the handover")))
    ('scan-failed
     '((?w wait "check again")
       (?g go "go on without the check")
       (?c cancel "cancel the handover")))
    (_
     '((?r retry "try the stage again")
       (?c cancel "cancel the handover")))))

(defun claude-code-ide-handover--describe-strays (strays)
  "Return a text that lists STRAYS: process ID, command and folder."
  (mapconcat (lambda (stray)
               (format "  %s  %s  (in %s)"
                       (plist-get stray :pid)
                       (or (plist-get stray :command) "?")
                       (or (plist-get stray :cwd) "?")))
             strays "\n"))

(defun claude-code-ide-handover--ask (run)
  "Ask the person what to do with RUN, which needs a person."
  (when (eq (claude-code-ide-handover--run-status run) 'needs-user)
    (let* ((choices (claude-code-ide-handover--choices run))
           (strays (claude-code-ide-handover--run-strays run))
           (answer (read-multiple-choice
                    (format "Handover %s: %s%s\nWhat now? "
                            (claude-code-ide-handover--run-id run)
                            (claude-code-ide-handover--run-message run)
                            (if strays
                                (concat ":\n" (claude-code-ide-handover--describe-strays strays))
                              ""))
                    (mapcar (lambda (choice)
                              (list (nth 0 choice) (symbol-name (nth 1 choice)) (nth 2 choice)))
                            choices))))
      (claude-code-ide-handover-resolve (claude-code-ide-handover--run-id run)
                                        (nth 1 (assq (car answer) choices))))))

(defun claude-code-ide-handover--stray-alive-p (stray)
  "Return non-nil when the process of STRAY still runs the same command."
  (when-let* ((pid (plist-get stray :pid))
              (attributes (ignore-errors (process-attributes pid))))
    (let ((command (plist-get stray :command))
          (args (alist-get 'args attributes))
          (comm (alist-get 'comm attributes)))
      (or (null command)
          (and (stringp args) (string-prefix-p (car (split-string command)) args))
          (and (stringp comm) (string-match-p (regexp-quote comm) command))))))

(defun claude-code-ide-handover--end-strays (strays signal)
  "Send SIGNAL to each of STRAYS that still runs the same command."
  (dolist (stray strays)
    (when (claude-code-ide-handover--stray-alive-p stray)
      (ignore-errors (signal-process (plist-get stray :pid) signal)))))

(defun claude-code-ide-handover--rescan (run &optional then)
  "Scan the worktree of RUN again after `claude-code-ide-handover-stray-wait'.
THEN, when given, runs first, with the strays of RUN."
  (setf (claude-code-ide-handover--run-status run) 'running)
  (claude-code-ide-handover--save run)
  (setf (claude-code-ide-handover--run-timer run)
        (run-at-time claude-code-ide-handover-stray-wait nil
                     (lambda ()
                       (when then (funcall then (claude-code-ide-handover--run-strays run)))
                       (claude-code-ide-handover--after-stop
                        run (claude-code-ide-handover--scan run))))))

(defun claude-code-ide-handover--read-unfinished (prompt)
  "Read the ID of an unfinished handover with PROMPT."
  (let ((ids (delete-dups
              (mapcar #'claude-code-ide-handover--run-id
                      (cl-remove-if-not #'claude-code-ide-handover--unfinished-p
                                        (append (hash-table-values claude-code-ide-handover--runs)
                                                (claude-code-ide-handover--registry-runs)))))))
    (unless ids (user-error "No handover is unfinished"))
    (if (cdr ids) (completing-read prompt ids nil t) (car ids))))

(defun claude-code-ide-handover-resolve (handover-id &optional action)
  "Answer the question of the handover HANDOVER-ID with ACTION.
ACTION is one of the choices that the handover offers:
- `end': end the stray processes (SIGTERM, then SIGKILL), then check again.
- `wait': wait `claude-code-ide-handover-stray-wait' seconds, then check again.
- `go': go on although the process check failed.
- `retry': run the stage again.
- `cancel': cancel the handover.  When the source is stopped already,
  it stays stopped; `claude-code-ide-reopen-session' starts it again.
Interactively, choose the handover and the action."
  (interactive (list (claude-code-ide-handover--read-unfinished "Handover: ") nil))
  (let ((run (or (gethash handover-id claude-code-ide-handover--runs)
                 (user-error "Handover %s does not run in this Emacs; M-x claude-code-ide-handover-recover"
                             handover-id))))
    (if (null action)
        (if (eq (claude-code-ide-handover--run-status run) 'needs-user)
            (claude-code-ide-handover--ask run)
          (message "Handover %s is %s at %s" handover-id
                   (claude-code-ide-handover--run-status run)
                   (claude-code-ide-handover--run-stage run)))
      (unless (assq action (mapcar (lambda (c) (list (nth 1 c)))
                                   (claude-code-ide-handover--choices run)))
        (user-error "Handover %s cannot %s now" handover-id action))
      (pcase action
        ('cancel (claude-code-ide-handover-cancel handover-id))
        ('wait (claude-code-ide-handover--rescan run))
        ('end
         (let ((strays (claude-code-ide-handover--run-strays run)))
           (claude-code-ide-handover--end-strays strays 'SIGTERM)
           (claude-code-ide-handover--rescan
            run (lambda (_) (claude-code-ide-handover--end-strays strays 'SIGKILL)))))
        ('go
         (setf (claude-code-ide-handover--run-status run) 'running)
         (claude-code-ide-handover--source-stopped run))
        ('retry
         (setf (claude-code-ide-handover--run-status run) 'running
               (claude-code-ide-handover--run-reason run) nil
               (claude-code-ide-handover--run-message run) nil)
         (claude-code-ide-handover--save run)
         (claude-code-ide-handover--schedule run 0)))
      (claude-code-ide-handover--result run))))

(defun claude-code-ide-handover-cancel (handover-id)
  "Cancel the unfinished handover HANDOVER-ID.
A handover whose target started can no longer be cancelled; the target
is the new conversation then.  A cancel after the stop leaves the
source stopped."
  (interactive (list (claude-code-ide-handover--read-unfinished "Cancel handover: ")))
  (let ((run (claude-code-ide-handover--find handover-id)))
    (cond
     ((null run) (user-error "No handover %s" handover-id))
     ((not (claude-code-ide-handover--unfinished-p run))
      (user-error "Handover %s is %s already" handover-id (claude-code-ide-handover--run-status run)))
     ((and (not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                  'target-started))
           (let ((target (claude-code-ide-handover--run-target-id run)))
             (and target (claude-code-ide-instance-by-id target)
                  (claude-code-ide-instance-live-p (claude-code-ide-instance-by-id target)))))
      (user-error "The target of handover %s runs already" handover-id))
     (t
      (puthash (claude-code-ide-handover--run-id run) run claude-code-ide-handover--runs)
      (claude-code-ide-handover--finish
       run 'cancelled 'user-cancelled
       (if (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                             'source-stopped)
           "the source stays current"
         "the source is stopped; M-x claude-code-ide-reopen-session starts it again"))
      (claude-code-ide-handover--result run)))))

;;; The document

(defun claude-code-ide-handover--folder (run)
  "Return the handover folder in the worktree of RUN."
  (file-name-as-directory
   (expand-file-name claude-code-ide-handover-directory
                     (claude-code-ide-handover--run-worktree run))))

(defun claude-code-ide-handover-exclude (worktree)
  "Add the handover folder to the Git exclude file of WORKTREE.
The file is `git rev-parse --git-path info/exclude', so a linked
worktree uses the exclude file of its repository.  Return the file, or
nil when WORKTREE is not in Git."
  (when-let* ((path (claude-code-ide-handover--git worktree "rev-parse" "--git-path" "info/exclude"))
              ((not (string-empty-p path))))
    (let* ((file (expand-file-name path worktree))
           (line (concat (string-trim-right claude-code-ide-handover-directory "/") "/"))
           (text (and (file-readable-p file)
                      (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string)))))
      (unless (and text (member line (split-string text "\n")))
        (make-directory (file-name-directory file) t)
        (with-temp-buffer
          (when text
            (insert text)
            (unless (or (string-empty-p text) (string-suffix-p "\n" text))
              (insert "\n")))
          (insert line "\n")
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (point-min) (point-max) file nil 'silent))))
      file)))

(defun claude-code-ide-handover--write-file (file text)
  "Write TEXT to FILE atomically, with mode 0600 in a 0700 folder."
  (let ((dir (file-name-directory file)))
    (with-file-modes #o700 (make-directory dir t))
    (let ((tmp (with-file-modes #o600 (make-temp-file (expand-file-name ".doc-" dir) nil ".tmp"))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region text nil tmp nil 'silent))
            (rename-file tmp file t))
        (when (file-exists-p tmp) (delete-file tmp))))))

(defun claude-code-ide-handover--document-text (run)
  "Return the text of the handover document of RUN."
  (claude-code-ide-transcript-handover-document
   :source (claude-code-ide-handover--run-source-leg run)
   :chain (claude-code-ide-handover--run-chain run)
   :context (claude-code-ide-handover--run-context run)
   :budget claude-code-ide-handover-budget
   :handover-id (claude-code-ide-handover--run-id run)
   :target-provider (claude-code-ide-handover--run-target-provider run)
   :summary-file (claude-code-ide-handover--run-summary-file run)
   :session-server claude-code-ide-handover-session-server-detection))

(defun claude-code-ide-handover--write-document (run)
  "Write the handover document of RUN with its hash, then start the target."
  (let* ((id (claude-code-ide-handover--run-id run))
         (folder (claude-code-ide-handover--folder run))
         (file (expand-file-name (concat id ".md") folder)))
    (setf (claude-code-ide-handover--run-summary-file run)
          (expand-file-name (concat id "-state.md") folder))
    (claude-code-ide-handover-exclude (claude-code-ide-handover--run-worktree run))
    (let ((text (claude-code-ide-handover--document-text run)))
      (claude-code-ide-handover--write-file file text)
      (setf (claude-code-ide-handover--run-document run) file
            (claude-code-ide-handover--run-document-hash run) (secure-hash 'sha256 text)))
    (when (claude-code-ide-handover--enter run 'target-started)
      (claude-code-ide-handover--start-target run))))

(defun claude-code-ide-handover--document (run)
  "Return the text of the document of RUN, when its file has the recorded hash."
  (when-let* ((file (claude-code-ide-handover--run-document run))
              ((file-readable-p file)))
    (let ((text (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8))
                    (insert-file-contents file))
                  (buffer-string))))
      (and (equal (secure-hash 'sha256 text) (claude-code-ide-handover--run-document-hash run))
           text))))

;;; The target

(defun claude-code-ide-handover--target-leg (run &optional pending)
  "Return the leg plist of the target of RUN.
PENDING non-nil marks the leg as not committed yet."
  (append (list :provider (claude-code-ide-handover--run-target-provider run)
                :instance-id (claude-code-ide-handover--run-target-id run)
                :native-id (claude-code-ide-handover--run-target-native-id run)
                :worktree (claude-code-ide-handover--run-worktree run)
                :handover-id (claude-code-ide-handover--run-id run)
                :document-hash (claude-code-ide-handover--run-document-hash run)
                :summary-file (claude-code-ide-handover--run-summary-file run)
                :start-commit (claude-code-ide-handover--git
                               (claude-code-ide-handover--run-worktree run) "rev-parse" "HEAD"))
          (when pending (list :pending t))))

(defun claude-code-ide-handover--target-chain (run &optional pending)
  "Return the chain of the target of RUN: the earlier legs, the source, the target.
PENDING is as for `claude-code-ide-handover--target-leg'."
  (let* ((source (claude-code-ide-handover--run-source-leg run))
         (earlier (cl-remove-if (lambda (leg)
                                  (equal (plist-get leg :instance-id)
                                         (plist-get source :instance-id)))
                                (claude-code-ide-handover--run-chain run))))
    (append earlier
            (list (let ((leg (copy-sequence source)))
                    (cl-remf leg :pending)
                    leg))
            (list (claude-code-ide-handover--target-leg run pending)))))

(defun claude-code-ide-handover--start-spec (run text)
  "Return the start spec of the target of RUN, with TEXT as its first prompt."
  (let* ((id (claude-code-ide-handover--run-target-id run))
         (entry (claude-code-ide-session-registry-entry-of id))
         (last (max (or (claude-code-ide-instance-current-generation id) 0)
                    (or (and entry (claude-code-ide-session-registry-entry-generation entry)) 0))))
    (claude-code-ide-start-spec-create
     :directory (claude-code-ide-handover--run-directory run)
     :instance-name (claude-code-ide-handover--run-instance-name run)
     :prompt text
     :provider (claude-code-ide-handover--run-target-provider run)
     :instance-id id
     ;; A start of an instance ID that has a record names its generation
     :last-generation (and (> last 0) last)
     :role (claude-code-ide-handover--run-role run)
     :resume-id (claude-code-ide-handover--run-fork-id run)
     :fork (and (claude-code-ide-handover--run-fork-id run) t))))

(defun claude-code-ide-handover--start-target (run)
  "Start the target of RUN with the document as its first prompt.
A target that a recovery finds identified is resumed instead."
  (unless (claude-code-ide-handover--run-target-id run)
    (setf (claude-code-ide-handover--run-target-id run) (claude-code-ide-instance-new-id))
    ;; The target ID is in the registry before the start
    (claude-code-ide-handover--save run))
  (let ((text (or (claude-code-ide-handover--document run)
                  (error "The handover document %s is missing or changed"
                         (claude-code-ide-handover--run-document run))))
        (claude-code-ide-handover--allowed (claude-code-ide-handover--run-id run)))
    (condition-case err
        (claude-code-ide--start-session nil nil (claude-code-ide-handover--start-spec run text))
      ((error quit)
       (claude-code-ide-handover--needs-user
        run 'start-failed (format "The target did not start: %s" (error-message-string err)))))
    (when (eq (claude-code-ide-handover--run-status run) 'running)
      (claude-code-ide-session-registry-save-chain
       (claude-code-ide-handover--run-target-id run)
       (claude-code-ide-handover--target-chain run 'pending))
      (claude-code-ide-handover--check-identified run))))

(defun claude-code-ide-handover--check-identified (run)
  "Mark the target of RUN identified when its native ID is known now."
  (when-let* ((instance (claude-code-ide-instance-by-id (claude-code-ide-handover--run-target-id run)))
              (native (claude-code-ide-known-or-nil
                       (claude-code-ide-provider-call
                        (claude-code-ide-instance-provider instance) 'native-id instance)))
              ((stringp native)))
    (claude-code-ide-handover--identified run native)))

(defun claude-code-ide-handover--identified (run native-id)
  "Record the native ID NATIVE-ID of the target of RUN: stage target-identified."
  (when (and (eq (claude-code-ide-handover--run-status run) 'running)
             (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                               'target-identified))
    (setf (claude-code-ide-handover--run-target-native-id run) native-id)
    (claude-code-ide-handover--enter run 'target-identified)))

(defun claude-code-ide-handover--delivered (run)
  "Record that the target of RUN received the document, and commit."
  (when (and (eq (claude-code-ide-handover--run-status run) 'running)
             (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run) 'delivered))
    (when (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                            'target-identified)
      (claude-code-ide-handover--check-identified run))
    (when (claude-code-ide-handover--enter run 'delivered)
      (claude-code-ide-handover--commit run))))

(defun claude-code-ide-handover--commit (run)
  "Make the target of RUN the current instance of the chain."
  (when (claude-code-ide-handover--enter run 'committed)
    (let ((source (claude-code-ide-handover--run-source-id run))
          (target (claude-code-ide-handover--run-target-id run)))
      (claude-code-ide-session-registry-save-chain target (claude-code-ide-handover--target-chain run))
      (claude-code-ide-handover--finish run 'committed nil
                                        (format "%s %s -> %s %s"
                                                (claude-code-ide-handover--run-source-provider run)
                                                source
                                                (claude-code-ide-handover--run-target-provider run)
                                                target))
      ;; Queued prompts and review results go to the new instance
      (claude-code-ide-control-move-inbox source target))))

(defun claude-code-ide-handover--run-of-target (instance-id)
  "Return the unfinished run of this Emacs whose target is INSTANCE-ID, or nil."
  (cl-find-if (lambda (run)
                (and (eq (claude-code-ide-handover--run-status run) 'running)
                     (equal (claude-code-ide-handover--run-target-id run) instance-id)))
              (hash-table-values claude-code-ide-handover--runs)))

(defun claude-code-ide-handover--on-event (event)
  "Follow the target of a handover, and the requests of agents, with EVENT.
A `session-start' of a target gives its native ID.  A `prompt-submit'
of a target whose prompt is the document of its handover is the
delivery.  A `turn-end' of an instance with a handover request asks
the user."
  (let ((instance-id (plist-get event :instance-id))
        (data (plist-get event :data)))
    (pcase (plist-get event :event)
      ('session-start
       (when-let* ((run (claude-code-ide-handover--run-of-target instance-id))
                   (native (claude-code-ide-handover--event-value data "session_id"))
                   ((stringp native)))
         (claude-code-ide-handover--identified run native)))
      ('prompt-submit
       (when-let* ((run (claude-code-ide-handover--run-of-target instance-id))
                   (prompt (claude-code-ide-handover--event-value data "prompt"))
                   ((equal (claude-code-ide-transcript-document-id prompt)
                           (claude-code-ide-handover--run-id run))))
         ;; After the other event functions, which set the native ID
         (run-at-time 0 nil #'claude-code-ide-handover--delivered run)))
      ('turn-end
       (when-let* ((instance (claude-code-ide-instance-by-id instance-id))
                   ((claude-code-ide-instance-property instance :handover-request)))
         (run-at-time 0 nil #'claude-code-ide-handover--offer-request instance-id))))))

(add-hook 'claude-code-ide-event-functions #'claude-code-ide-handover--on-event)

;;; Recovery

(defun claude-code-ide-handover--target-delivered-p (run)
  "Return non-nil when the transcript of the target of RUN holds its document."
  (when-let* ((entry (claude-code-ide-session-registry-entry-of
                      (claude-code-ide-handover--run-target-id run)))
              (file (claude-code-ide-handover--transcript-file
                     (claude-code-ide-handover--run-target-provider run)
                     (or (claude-code-ide-handover--run-target-native-id run)
                         (claude-code-ide-session-registry-entry-session-id entry))
                     entry
                     (when-let* ((instance (claude-code-ide-instance-by-id
                                            (claude-code-ide-handover--run-target-id run)))
                                 ((fboundp 'claude-code-ide-transcript-instance-leg)))
                       (claude-code-ide-transcript-instance-leg instance)))))
    (cl-some (lambda (turn)
               (and (eq (plist-get turn :role) 'user)
                    (equal (claude-code-ide-transcript-document-id (plist-get turn :text))
                           (claude-code-ide-handover--run-id run))))
             (claude-code-ide-transcript-read file))))

(defun claude-code-ide-handover--resume-target (run)
  "Resume the identified target of RUN, and deliver the document when it lacks it."
  (let* ((id (claude-code-ide-handover--run-target-id run))
         (entry (claude-code-ide-session-registry-entry-of id))
         (claude-code-ide-handover--allowed (claude-code-ide-handover--run-id run)))
    (unless (and (claude-code-ide-instance-by-id id)
                 (claude-code-ide-instance-live-p (claude-code-ide-instance-by-id id)))
      (unless entry (error "The registry has no entry of the target %s" id))
      (unless (claude-code-ide-session-registry-entry-session-id entry)
        (setf (claude-code-ide-session-registry-entry-session-id entry)
              (claude-code-ide-handover--run-target-native-id run)))
      (claude-code-ide-session-registry--start-entry entry nil))
    (cond
     ((not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run) 'delivered))
      (claude-code-ide-handover--commit run))
     ((claude-code-ide-handover--target-delivered-p run)
      (claude-code-ide-handover--delivered run))
     (t
      (claude-code-ide-control-submit
       id (or (claude-code-ide-handover--document run)
              (error "The handover document %s is missing or changed"
                     (claude-code-ide-handover--run-document run)))
       :request-id (or (claude-code-ide-handover--run-request-id run)
                       (concat "handover-" (claude-code-ide-handover--run-id run)))
       :queue t)))))

(defun claude-code-ide-handover--recover-run (run interactive)
  "Continue the interrupted RUN of an Emacs that ended.  Return its result.
INTERACTIVE non-nil lets Emacs ask the person about stray processes."
  (puthash (claude-code-ide-handover--run-id run) run claude-code-ide-handover--runs)
  (setf (claude-code-ide-handover--run-status run) 'running
        (claude-code-ide-handover--run-interactive run) interactive)
  (let ((stage (claude-code-ide-handover--run-stage run)))
    (condition-case err
        (cond
         ;; Before the stop: the source stays current
         ((claude-code-ide-handover--stage< stage 'source-stopped)
          (claude-code-ide-handover--finish
           run 'cancelled 'recovered-before-stop "Emacs ended before the source stopped; it stays current"))
         ;; The stop may not have ended: check the worktree first
         ((eq stage 'source-stopped)
          (claude-code-ide-handover--after-stop run (claude-code-ide-handover--scan run)))
         ((eq stage 'document-written)
          (claude-code-ide-handover--write-document run))
         ((eq stage 'committed)
          (claude-code-ide-handover--commit run))
         ;; Never both: the source is not started again
         ((or (claude-code-ide-handover--run-target-native-id run)
              (when-let* ((entry (claude-code-ide-session-registry-entry-of
                                  (claude-code-ide-handover--run-target-id run))))
                (claude-code-ide-session-registry-entry-session-id entry)))
          (claude-code-ide-handover--resume-target run))
         (t
          (setf (claude-code-ide-handover--run-stage run) 'target-started)
          (claude-code-ide-handover--start-target run)))
      (error
       (claude-code-ide-handover--needs-user
        run 'step-failed (format "Recovery at %s failed: %s" stage (error-message-string err)))))
    (claude-code-ide-handover--result run)))

(defun claude-code-ide-handover--interrupted-runs ()
  "Return the unfinished runs in the registry that no live Emacs runs."
  (cl-remove-if
   (lambda (run)
     (or (gethash (claude-code-ide-handover--run-id run) claude-code-ide-handover--runs)
         (when-let* ((entry (claude-code-ide-session-registry-entry-of
                             (claude-code-ide-handover--run-source-id run))))
           (or (not (equal (claude-code-ide-session-registry-entry-host entry) (system-name)))
               (claude-code-ide-session-registry--other-emacs-p entry)))))
   (cl-remove-if-not #'claude-code-ide-handover--unfinished-p
                     (claude-code-ide-handover--registry-runs))))

;;;###autoload
(defun claude-code-ide-handover-recover (&optional early-only interactive)
  "Continue the handovers that an ended Emacs left unfinished.
A handover before the stage source-stopped is cancelled: its source
stays current.  A later one never starts its source again: its target
is resumed when its native ID is known, else started again with the
same document.  With EARLY-ONLY, only cancel the early ones.
INTERACTIVE non-nil (always for the command) lets Emacs ask about
stray processes.  Return the results."
  (interactive (list nil t))
  (let ((results nil) (late 0))
    (dolist (run (claude-code-ide-handover--interrupted-runs))
      (if (and early-only
               (not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                      'source-stopped)))
          (setq late (1+ late))
        (push (claude-code-ide-handover--recover-run run interactive) results)))
    (when (> late 0)
      (message "%d interrupted handover%s: M-x claude-code-ide-handover-recover continues them"
               late (if (= late 1) "" "s")))
    (nreverse results)))

(defun claude-code-ide-handover--recover-at-start ()
  "Recover the interrupted handovers when the session registry starts.
See `claude-code-ide-handover-recover-at-start'."
  (when (bound-and-true-p claude-code-ide-session-registry-mode)
    (run-with-idle-timer
     1 nil (lambda ()
             (condition-case err
                 (claude-code-ide-handover-recover (not claude-code-ide-handover-recover-at-start))
               (error (message "Handover recovery failed: %s" (error-message-string err))))))))

(add-hook 'claude-code-ide-session-registry-mode-hook #'claude-code-ide-handover--recover-at-start)

;;; Commands

(defun claude-code-ide-handover--instance-label (instance)
  "Return a label of INSTANCE for completion."
  (format "%s (%s, %s)"
          (claude-code-ide-format-value (claude-code-ide-instance-display-name instance))
          (claude-code-ide-instance-provider instance)
          (claude-code-ide-instance-id instance)))

(defun claude-code-ide-handover--current-instance ()
  "Return the instance of the current buffer, or nil."
  (when-let* ((session (ignore-errors (claude-code-ide--buffer-session))))
    (claude-code-ide-instance-of-session session)))

(defun claude-code-ide-handover--read-args (&optional instance-id)
  "Read the arguments of `claude-code-ide-handover'.
INSTANCE-ID, when given, is the source; else it is the instance of the
current buffer, or one that you choose."
  (let* ((instance (or (and instance-id (claude-code-ide-instance-by-id instance-id))
                       (claude-code-ide-handover--current-instance)
                       (let* ((instances (cl-remove-if-not #'claude-code-ide-instance-live-p
                                                           (claude-code-ide-instances)))
                              (candidates (mapcar (lambda (i)
                                                    (cons (claude-code-ide-handover--instance-label i) i))
                                                  instances)))
                         (unless candidates (user-error "No instance runs"))
                         (cdr (assoc (completing-read "Hand over: " candidates nil t) candidates)))))
         (source-provider (claude-code-ide-instance-provider instance))
         (others (remq source-provider (claude-code-ide-provider-names)))
         (default (symbol-name (or (car others) source-provider)))
         (target (intern (completing-read (format "Target provider (default %s): " default)
                                          (mapcar #'symbol-name (claude-code-ide-provider-names))
                                          nil t nil nil default)))
         (fork-id (claude-code-ide-handover--fork-id
                   (claude-code-ide-handover--chain-of (claude-code-ide-instance-id instance))
                   (list :provider source-provider
                         :native-id (claude-code-ide-known-or-nil
                                     (claude-code-ide-instance-native-id instance)))
                   target))
         (method (if fork-id
                     (intern (completing-read "Method (default fresh): " '("fresh" "fork")
                                              nil t nil nil "fresh"))
                   'fresh))
         (context (let ((text (read-string "Context for the target (empty for none): ")))
                    (unless (string-empty-p (string-trim text)) text)))
         (state (claude-code-ide-instance-state instance))
         (interrupt (and (memq (plist-get state :state) '(working waiting-for-user))
                         (not (claude-code-ide-handover--quiet-state-p state))
                         (y-or-n-p (format "%s is %s.  Interrupt it (else wait until it is idle)? "
                                           (claude-code-ide-handover--instance-label instance)
                                           (plist-get state :state)))))
         (force (and (memq (plist-get state :state) '(waiting-for-task disconnected))
                     (yes-or-no-p
                      (format "%s is %s%s.  Hand over anyway? "
                              (claude-code-ide-handover--instance-label instance)
                              (plist-get state :state)
                              (if (plist-get state :reason)
                                  (format "/%s" (plist-get state :reason))
                                ""))))))
    (when (and (memq (plist-get state :state) '(waiting-for-task disconnected)) (not force))
      (user-error "Handover not started"))
    (list (claude-code-ide-instance-id instance) target method context interrupt force)))

;;;###autoload
(defun claude-code-ide-handover (instance-id target-provider &optional method context interrupt force)
  "Hand the work of INSTANCE-ID to a new conversation of TARGET-PROVIDER.
METHOD is `fresh' or `fork', CONTEXT optional text for the target,
INTERRUPT non-nil to interrupt a busy source, and FORCE non-nil to go
on while its subagents or background tasks run, or while its state is
unknown.  Interactively, the source is the instance of the current
buffer, else one that you choose, and Emacs asks for the rest.  Emacs
asks you about stray processes after the stop.  See
`claude-code-ide-handover-session'."
  (interactive (claude-code-ide-handover--read-args))
  (let ((result (claude-code-ide-handover-session
                 instance-id target-provider :method (or method 'fresh) :context context
                 :interrupt interrupt :force force :interactive t)))
    (if (eq (plist-get result :status) 'error)
        (user-error "Handover refused: %s%s" (plist-get result :reason)
                    (if (plist-get result :message) (concat ": " (plist-get result :message)) ""))
      (message "Handover %s started: %s -> %s" (plist-get result :handover-id)
               instance-id target-provider))
    result))

;;; Requests of agents

(defun claude-code-ide-handover--offer-request (instance-id)
  "Ask the user about the handover request of INSTANCE-ID, after its turn end."
  (when-let* ((instance (claude-code-ide-instance-by-id instance-id))
              (request (claude-code-ide-instance-property instance :handover-request)))
    (claude-code-ide-instance-set-property instance :handover-request nil)
    (when (and (claude-code-ide-instance-live-p instance)
               (y-or-n-p (format "%s asks for a handover to %s%s.  Hand over now? "
                                 (claude-code-ide-handover--instance-label instance)
                                 (plist-get request :target-provider)
                                 (if (plist-get request :context)
                                     (format " (%s)" (plist-get request :context))
                                   ""))))
      (claude-code-ide-handover instance-id (plist-get request :target-provider)
                                (plist-get request :method) (plist-get request :context)))))

(defun claude-code-ide-handover-request (instance-id target-provider &optional method context)
  "Save a handover request of the agent INSTANCE-ID, and return at once.
TARGET-PROVIDER (nil: another provider than the source's), METHOD and
CONTEXT are as for `claude-code-ide-handover'.  After the next turn end
of INSTANCE-ID, Emacs asks the user whether to hand over.  Emacs never
starts the handover without that yes."
  (let* ((instance (claude-code-ide-instance-by-id instance-id))
         (target (cond ((stringp target-provider)
                        (unless (string-empty-p target-provider) (intern target-provider)))
                       (target-provider)
                       (instance (car (remq (claude-code-ide-instance-provider instance)
                                            (claude-code-ide-provider-names)))))))
    (cond
     ((not (and instance (claude-code-ide-instance-live-p instance)))
      (claude-code-ide-handover--error 'not-running nil instance-id))
     ((not (and target (claude-code-ide-get-provider target)))
      (claude-code-ide-handover--error 'unknown-provider
                                       (format "No provider named %s" target) instance-id))
     (t
      (claude-code-ide-instance-set-property
       instance :handover-request
       (list :target-provider target
             :method (if (and (stringp method) (string= method "fork")) 'fork 'fresh)
             :context (and (stringp context) (not (string-empty-p context)) context)
             :time (float-time)))
      (list :status 'requested :instance-id instance-id :target-provider target
            :message "Emacs asks the user after your turn ends.  Finish your turn now.")))))

(defun claude-code-ide-handover--mcp-request (&optional target-provider method reason)
  "MCP tool request_handover: save a request of the calling instance.
TARGET-PROVIDER, METHOD and REASON are the tool arguments."
  (let ((instance-id (and (fboundp 'claude-code-ide-mcp-request-instance-id)
                          (claude-code-ide-mcp-request-instance-id))))
    (claude-code-ide-control--json
     (if instance-id
         (claude-code-ide-handover-request instance-id target-provider method reason)
       (claude-code-ide-handover--error 'no-instance "The request has no instance")))))

(when (and claude-code-ide-handover-enable-request-tool
           (fboundp 'claude-code-ide-mcp-request-instance-id))
  (claude-code-ide-make-tool
   :name "request_handover"
   :function #'claude-code-ide-handover--mcp-request
   :description "Ask the user to hand your work over to a new conversation, for example of another provider when your usage limit is near. This only saves the request and returns at once. After your turn ends, Emacs asks the user; on a yes, your session stops and the new one gets a handover document. Finish your turn after the call."
   :args '((:name "target_provider" :type string :optional t
                  :description "Provider of the new conversation: claude or codex. Default: the other provider.")
           (:name "method" :type string :optional t
                  :description "fresh (default): a new conversation. fork: fork the latest conversation of that provider in the chain.")
           (:name "reason" :type string :optional t
                  :description "Why the handover is needed; the user and the new conversation see it."))))

;;; The control operation and the coordinator tools

(defun claude-code-ide-handover--flag (value)
  "Return non-nil when the MCP argument VALUE is true."
  (and value (not (eq value :json-false)) (not (member value '("false" "" "no" "0"))) t))

(defun claude-code-ide-handover--mcp-handover (instance-id target-provider &optional method context
                                                           interrupt force request-id)
  "MCP tool: hand INSTANCE-ID over to TARGET-PROVIDER.
METHOD, CONTEXT, INTERRUPT, FORCE and REQUEST-ID are the tool arguments."
  (claude-code-ide-control--json
   (claude-code-ide-control-call
    'handover instance-id target-provider
    :method (if (and (stringp method) (string= method "fork")) 'fork 'fresh)
    :context (unless (claude-code-ide-control--blank-p context) context)
    :interrupt (claude-code-ide-handover--flag interrupt)
    :force (claude-code-ide-handover--flag force)
    :request-id (unless (claude-code-ide-control--blank-p request-id) request-id))))

(defun claude-code-ide-handover--mcp-status (handover-id)
  "MCP tool: return the result of the handover HANDOVER-ID (or request ID)."
  (claude-code-ide-control--json (claude-code-ide-handover-status handover-id)))

(claude-code-ide-control-define-operation 'handover #'claude-code-ide-handover-session)

(claude-code-ide-control-define-tool
 :name "claude-code-ide-control-handover"
 :function #'claude-code-ide-handover--mcp-handover
 :description "Hand the work of an instance to a new conversation of a provider (claude or codex). The source stops; the target gets a handover document as its first prompt. Returns at once with a handover ID; poll claude-code-ide-control-handover-status. The status needs-user means that a person must answer in Emacs (for example about processes that still run in the worktree)."
 :args (list claude-code-ide-control--instance-id-arg
             '(:name "target_provider" :type string :description "Provider of the target: claude or codex.")
             '(:name "method" :type string :optional t
                     :description "fresh (default) or fork (fork the latest conversation of the target provider in the chain).")
             '(:name "context" :type string :optional t
                     :description "Your own text for the handover document; it has priority over older history.")
             '(:name "interrupt" :type boolean :optional t
                     :description "Interrupt the source when it is busy. Default: wait until it is idle.")
             '(:name "force" :type boolean :optional t
                     :description "Hand over while subagents or background tasks run.")
             '(:name "request_id" :type string :optional t
                     :description "ID that makes the request idempotent.")))

(claude-code-ide-control-define-tool
 :name "claude-code-ide-control-handover-status"
 :function #'claude-code-ide-handover--mcp-status
 :description "Return the status of a handover: running, needs-user, committed, cancelled or failed, with its stage, the target instance ID and the stray processes."
 :args '((:name "handover_id" :type string :description "Handover ID or request ID of the handover.")))

(provide 'claude-code-ide-handover)

;;; claude-code-ide-handover.el ends here
