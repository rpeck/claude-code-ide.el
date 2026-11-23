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
(declare-function claude-code-ide-process--terminal-process "claude-code-ide-process" (instance process))
(declare-function claude-code-ide-process-live-sessions "claude-code-ide-process" ())
(declare-function claude-code-ide-process-session-live-p "claude-code-ide-process" (session))
(declare-function claude-code-ide-process--same-start-p "claude-code-ide-process" (a b))
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

(defcustom claude-code-ide-handover-recover-at-start t
  "When non-nil, continue interrupted handovers when the registry starts.
A handover that a crash cut off before its source stopped is cancelled,
and its source stays current.  A later one resumes or starts again
only its target, never the source.  With nil, only the early ones are
cancelled at the start, and the later ones wait for
`claude-code-ide-restore-sessions' or `claude-code-ide-handover-recover'."
  :type 'boolean
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-unsaved-target 'fresh
  "What the recovery does with a target that never saved its conversation.
A crash right after the stage target-identified can end the target CLI
before it saves its first turn.  Its native ID is known, but a resume
of it fails: Claude Code prints \"No conversation found with session
ID\".  The target counts as unsaved when its provider finds no
transcript file for its native ID (for Claude Code the session file of
its registry entry, for Codex its rollout file).  The check runs after
the clean worktree scan, just before the start, so that a target CLI
that saves its transcript while the recovery waits for strays is
resumed.
- `fresh': start the target fresh, with the same instance ID and the
  same document.  A Claude Code target gets the same session ID
  (--session-id); a fork, and a Codex target, get the new ID that the
  CLI chooses.  No person is asked.
- `ask': the old order.  The recovery resumes the target; that resume
  fails, and then the handover needs a person (reason `target-exited').
  The choice retry starts the target again with the same document.
A target with a saved conversation is resumed in both cases."
  :type '(choice (const :tag "Start the target fresh" fresh)
                 (const :tag "Resume as before, then ask a person" ask))
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-continue 'ask
  "Whether the target goes on with the task after a handover commits.
The target reads its document, writes its state summary and replies
ready.  With a yes, the commit then sends it one more prompt: go on
with the task of its state summary now.  The prompt goes through the
inbox of the target, with the request ID handover-continue:ID, so it
waits until the target is idle and goes out at most once.
- `ask': the interactive handover (\[claude-code-ide-handover], or H in
  the status buffer) asks once, with its other questions: y (yes, this
  time), n (no, this time), a (always, saved), v (never, saved).  A
  call from Lisp or a coordinator never asks, and counts as `always'.
- `always': send the prompt.
- `never': send nothing; the target waits for your next prompt.
The key :continue of `claude-code-ide-handover-session' wins over this
option."
  :type '(choice (const :tag "Ask at an interactive handover" ask)
                 (const :tag "Always go on" always)
                 (const :tag "Never go on" never))
  :group 'claude-code-ide-handover)

(defconst claude-code-ide-handover--continue-prompt
  "The handover is complete. Go on now with the task that your state summary describes, from its next step. Do not wait for another prompt."
  "The prompt that tells a handover target to go on after the commit.
See `claude-code-ide-handover-continue'.")

(defcustom claude-code-ide-handover-delivery-timeout 600
  "Seconds that a started target has to get its handover document.
Without the delivery in that time, the handover needs a person, who
can wait again or cancel it."
  :type 'number
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-watch-interval 5
  "Seconds between two checks of a target that waits for its document."
  :type 'number
  :group 'claude-code-ide-handover)

(defcustom claude-code-ide-handover-ack-wait 10
  "Seconds that the quiescing waits for the acknowledgement of sent prompts.
A prompt that the inbox sent to the source before the hold, and whose
acknowledgement did not come, makes the stop wait this long.  Then it
moves to the target with a note that it may have reached the source."
  :type 'number
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
  (context-file nil :documentation "Private file that keeps the context, or nil.")
  (context-hash nil :documentation "SHA-256 of the context in that file.")
  (interrupt nil :documentation "Non-nil to interrupt a busy source.")
  (force nil :documentation "Non-nil to go on while subagents or tasks run.")
  (interactive nil :documentation "Non-nil when a person started it in Emacs.")
  (continue nil :documentation "Non-nil to send the continue prompt to the target at the commit.")
  (continue-sent nil :documentation "Non-nil after the inbox of the target accepted the continue prompt.")
  (chain-saved nil :documentation "Non-nil after the commit saved the chain of the target.")
  (missing-entry nil :documentation "`source' or `target': the registry entry that a save missed, or nil.")
  (stage 'requested :documentation "The stage that the run is in.")
  (status 'running :documentation "`running', `needs-user', `committed', `cancelled' or `failed'.")
  (reason nil :documentation "Symbol that says why the status is what it is.")
  (message nil :documentation "Text for people, or nil.")
  (strays nil :documentation "Stray processes of the stop, as plists.")
  (worktree nil :documentation "Working tree of the source.")
  (directory nil :documentation "Project directory of the source.")
  (instance-name nil :documentation "Instance name of the source.")
  (source-session-id nil :documentation "ID of the MCP session of the source in this Emacs, or nil.
The registry does not keep it: the sessions of an Emacs end with it.")
  (role nil :documentation "Role of the source.")
  (source-leg nil :documentation "Leg plist of the source, from the quiescing.")
  (chain nil :documentation "Legs of the chain of the source, oldest first.")
  (document nil :documentation "File of the handover document.")
  (document-hash nil :documentation "SHA-256 of the document.")
  (summary-file nil :documentation "State summary file of the target.")
  (interrupted nil :documentation "Non-nil after the interrupt was sent.")
  (deadline nil :documentation "Float time when the quiescing gives up.")
  (delivery-deadline nil :documentation "Float time when the wait for the delivery ends.")
  (timer nil :documentation "The timer of the next step, or nil.")
  (watch nil :documentation "The timer that watches the target, or nil.")
  (owner nil :documentation "Owner in the registry: `self', `other', or nil (ended).")
  (owner-pid nil :documentation "Process ID of the Emacs that owns the run in the registry.")
  (owner-host nil :documentation "Host name of that Emacs, for people.")
  (continuation nil :documentation "What a clean scan does next: `start-target', `resume-target', `cancel', or nil.")
  (ack-deadline nil :documentation "Float time when the wait for acknowledgements ends.")
  (ended nil :documentation "Non-nil after the status functions got the end of the run.
The registry does not keep it.")
  (batch-next nil :documentation "IDs of the sources that the batch of the run hands over next.
The registry does not keep it: a crash ends the batch.")
  (created-at nil)
  (updated-at nil))

(defvar claude-code-ide-handover--runs (make-hash-table :test 'equal)
  "The handovers of this Emacs, by handover ID.")

(defvar claude-code-ide-handover--status-functions nil
  "Functions that get a run at its end, and each time it needs a person.
`claude-code-ide-handover--finish' calls them once for each run, after
the final save and the release of the inbox hold;
`claude-code-ide-handover--needs-user' calls them after each save of
the status `needs-user'.  An error of a function gives a message, and
the next function runs.")

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
        (cons 'start (plist-get stray :start))
        (cons 'command (plist-get stray :command))
        (cons 'cwd (plist-get stray :cwd))
        (cons 'reason (claude-code-ide-handover--name (plist-get stray :reason)))
        (cons 'own (and (plist-get stray :own) t))))

(defun claude-code-ide-handover--stray-from-alist (alist)
  "Return the stray plist of the registry ALIST."
  (list :pid (alist-get 'pid alist)
        :start (alist-get 'start alist)
        :command (alist-get 'command alist)
        :cwd (alist-get 'cwd alist)
        :reason (claude-code-ide-handover--symbol (alist-get 'reason alist))
        :own (eq (alist-get 'own alist) t)))

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
           (cons 'context_file (claude-code-ide-handover--run-context-file run))
           (cons 'context_hash (claude-code-ide-handover--run-context-hash run))
           (cons 'continuation (claude-code-ide-handover--name
                                (claude-code-ide-handover--run-continuation run)))
           (when leg
             (cons 'source_leg (claude-code-ide-session-registry-leg-to-alist leg)))
           (when (claude-code-ide-handover--run-strays run)
             (cons 'strays (vconcat (mapcar #'claude-code-ide-handover--stray-to-alist
                                            (claude-code-ide-handover--run-strays run)))))
           (cons 'interactive (and (claude-code-ide-handover--run-interactive run) t))
           (cons 'continue (and (claude-code-ide-handover--run-continue run) t))
           (cons 'continue_sent (and (claude-code-ide-handover--run-continue-sent run) t))
           (cons 'chain_saved (and (claude-code-ide-handover--run-chain-saved run) t))
           ;; The owner of the run: this Emacs
           (cons 'emacs_pid (emacs-pid))
           (cons 'emacs_start_time (claude-code-ide-session-registry--emacs-start-time))
           (cons 'host_id (claude-code-ide-session-registry-host-id))
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
     :context-file (alist-get 'context_file alist)
     :context-hash (alist-get 'context_hash alist)
     :context (claude-code-ide-handover--read-context
               (alist-get 'context_file alist) (alist-get 'context_hash alist))
     :continuation (claude-code-ide-handover--symbol (alist-get 'continuation alist))
     :source-leg (and (consp leg) (claude-code-ide-session-registry-leg-from-alist leg))
     :chain (claude-code-ide-session-registry-entry-legs entry)
     :strays (mapcar #'claude-code-ide-handover--stray-from-alist (alist-get 'strays alist))
     :interactive (alist-get 'interactive alist)
     ;; An older record has no field: the old behavior, no prompt
     :continue (eq (alist-get 'continue alist) t)
     :continue-sent (eq (alist-get 'continue_sent alist) t)
     :chain-saved (eq (alist-get 'chain_saved alist) t)
     :owner (claude-code-ide-session-registry--handover-owner alist)
     :owner-pid (alist-get 'emacs_pid alist)
     :owner-host (alist-get 'host alist)
     :created-at (alist-get 'created_at alist)
     :updated-at (alist-get 'updated_at alist))))

(defun claude-code-ide-handover--entry-missing (run text)
  "Stop RUN, because the registry entry that TEXT names is missing.
A retry cannot help, so the run needs a person; nothing is saved."
  (unless (eq (claude-code-ide-handover--run-reason run) 'registry-entry-missing)
    (dolist (timer (list (claude-code-ide-handover--run-timer run)
                         (claude-code-ide-handover--run-watch run)))
      (when (timerp timer) (cancel-timer timer)))
    (setf (claude-code-ide-handover--run-timer run) nil
          (claude-code-ide-handover--run-watch run) nil
          (claude-code-ide-handover--run-status run) 'needs-user
          (claude-code-ide-handover--run-reason run) 'registry-entry-missing
          (claude-code-ide-handover--run-message run) text)
    (message "Handover %s needs you: %s" (claude-code-ide-handover--run-id run) text)
    (claude-code-ide-handover--run-status-functions run)))

(defun claude-code-ide-handover--save (run &optional drop)
  "Save RUN in the registry entry of its source.  Return non-nil when saved.
nil means that the lock was busy, or that the entry is missing; then
RUN needs a person (`registry-entry-missing'), and no retry runs.
DROP is as for `claude-code-ide-session-registry-save-handover'."
  (setf (claude-code-ide-handover--run-updated-at run) (claude-code-ide-handover--now))
  (pcase (claude-code-ide-session-registry-save-handover
          (claude-code-ide-handover--run-source-id run)
          (claude-code-ide-handover--to-alist run)
          drop)
    (:missing
     (setf (claude-code-ide-handover--run-missing-entry run) 'source)
     (claude-code-ide-handover--entry-missing
      run (format "The session registry has no entry of the source %s"
                  (claude-code-ide-handover--run-source-id run)))
     nil)
    (result result)))

(defun claude-code-ide-handover--save-chain (run legs)
  "Save LEGS as the chain of the target of RUN.  Return non-nil when saved.
A missing target entry makes RUN need a person, as for
`claude-code-ide-handover--save'."
  (pcase (claude-code-ide-session-registry-save-chain
          (claude-code-ide-handover--run-target-id run) legs)
    (:missing
     (setf (claude-code-ide-handover--run-missing-entry run) 'target)
     (claude-code-ide-handover--entry-missing
      run (format "The session registry has no entry of the target %s"
                  (claude-code-ide-handover--run-target-id run)))
     ;; The source entry is there: its record says needs-user too, so
     ;; that a restart shows the same state as this Emacs
     (claude-code-ide-handover--save run)
     nil)
    (result result)))

;;; The context of the coordinator

(defun claude-code-ide-handover--read-context (file hash)
  "Return the context in FILE when it has the SHA-256 HASH, else nil."
  (when (and (stringp file) (stringp hash) (file-readable-p file))
    (let ((text (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8))
                    (insert-file-contents file))
                  (buffer-string))))
      (if (equal (secure-hash 'sha256 text) hash)
          text
        (message "Handover context %s changed; the document goes without it" file)
        nil))))

(defun claude-code-ide-handover--write-context (run)
  "Keep the context of RUN in a private file next to its document.
The file is <worktree>/.handover/<id>-context.md (mode 0600); its path
and hash go into the registry record, so that a rewrite of the
document after a crash still has the context."
  (when-let* ((context (claude-code-ide-handover--run-context run))
              ((not (claude-code-ide-handover--run-context-file run))))
    (let ((file (expand-file-name (concat (claude-code-ide-handover--run-id run) "-context.md")
                                  (claude-code-ide-handover--folder run))))
      (claude-code-ide-handover-exclude (claude-code-ide-handover--run-worktree run))
      (claude-code-ide-handover--write-file file context)
      (setf (claude-code-ide-handover--run-context-file run) file
            (claude-code-ide-handover--run-context-hash run) (secure-hash 'sha256 context)))))

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
         :continue (claude-code-ide-handover--run-continue run)
         :reason (claude-code-ide-handover--run-reason run)
         :message (claude-code-ide-handover--run-message run)
         :document (claude-code-ide-handover--run-document run)
         :document-hash (claude-code-ide-handover--run-document-hash run)
         :strays (mapcar (lambda (stray)
                           (list :pid (plist-get stray :pid)
                                 :command (plist-get stray :command)
                                 :cwd (plist-get stray :cwd)
                                 :reason (plist-get stray :reason)
                                 :own (plist-get stray :own)))
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

(defun claude-code-ide-handover--held-message (run)
  "Return the text for the working tree that the unfinished RUN holds."
  (claude-code-ide-control-held-message
   (claude-code-ide-handover--run-id run)
   (claude-code-ide-handover--directory-key (or (claude-code-ide-handover--run-worktree run)
                                                (claude-code-ide-handover--run-directory run)))
   (claude-code-ide-handover--run-stage run)))

(defun claude-code-ide-handover--guard-start (start &rest args)
  "Refuse a start in a working tree that a handover holds, then call START.
START is `claude-code-ide--start-session', and ARGS its arguments; the
third one is the start spec, or nil.  Only the start of the handover's
own target, in `claude-code-ide-handover--allowed', goes through: one
writer for each working tree.  Another start signals
`claude-code-ide-worktree-held', a `user-error'."
  (let* ((spec (nth 2 args))
         (directory (ignore-errors
                      (if spec
                          (claude-code-ide-start-spec-directory spec)
                        (claude-code-ide--get-working-directory))))
         (run (and directory (claude-code-ide-handover--holding-run directory))))
    (when (and run (not (equal claude-code-ide-handover--allowed
                               (claude-code-ide-handover--run-id run))))
      (signal 'claude-code-ide-worktree-held
              (list (claude-code-ide-handover--run-id run)
                    (claude-code-ide-handover--directory-key directory)
                    (claude-code-ide-handover--run-stage run))))
    (apply start args)))

(advice-add 'claude-code-ide--start-session :around #'claude-code-ide-handover--guard-start)

;;; Helpers for the source

(defun claude-code-ide-handover--event-value (data key)
  "Return the value of KEY, a string, in the hook DATA, or nil."
  (cond
   ((and (consp data) (keywordp (car data)))
    (plist-get data (intern (concat ":" key))))
   ((consp data)
    (cdr (or (assq (intern key) data) (assoc key data))))))

(defun claude-code-ide-handover--provider-transcript (provider native-ids entry)
  "Return the transcript file that the `transcript' operation of PROVIDER gives.
The operation gets a detached descriptor for each ID of NATIVE-IDS in
turn, with the instance ID and folder of the registry ENTRY.  Return
the first readable file, or nil.  The Codex operation keeps the search
of the Codex sessions folder as its fallback."
  (when (and provider (symbolp provider) (claude-code-ide-get-provider provider))
    (cl-some
     (lambda (native-id)
       (let ((file (ignore-errors
                     (claude-code-ide-provider-call
                      provider 'transcript
                      (claude-code-ide-instance-create
                       :id (and entry (claude-code-ide-session-registry-entry-key entry))
                       :provider provider
                       :native-id native-id
                       :project-root (or (and entry (claude-code-ide-session-registry-entry-project-dir
                                                     entry))
                                         'unknown))
                      'file))))
         (and (stringp file) (file-readable-p file) file)))
     (delete-dups (cl-remove-if-not #'stringp native-ids)))))

(defun claude-code-ide-handover--transcript-file (provider native-id &optional entry leg)
  "Return the transcript file of the conversation NATIVE-ID of PROVIDER, or nil.
It is the :transcript of LEG, else the transcript path of the registry
ENTRY, else:
- for Claude Code, the session file of ENTRY (its ID in its folder),
  and nothing more, so that the delivery check and the source leg read
  the same file as before;
- for another provider, the file that its `transcript' operation gives
  for NATIVE-ID or the native ID of ENTRY."
  (let ((candidates (list (plist-get leg :transcript)
                          (and entry (claude-code-ide-session-registry-entry-transcript-path entry))
                          ;; A Claude Code entry finds its file from its ID and folder
                          (and entry (eq provider 'claude)
                               (ignore-errors
                                 (claude-code-ide-session-registry--transcript-file entry))))))
    (or (cl-find-if (lambda (file) (and (stringp file) (file-readable-p file))) candidates)
        (unless (eq provider 'claude)
          (claude-code-ide-handover--provider-transcript
           provider
           (list native-id (and entry (claude-code-ide-session-registry-entry-session-id entry)))
           entry)))))

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

(declare-function claude-code-ide-codex-prepare-trust "claude-code-ide-codex-events" (&optional directory))
(declare-function claude-code-ide-codex-events--trust-key "claude-code-ide-codex-events" ())
(declare-function claude-code-ide-codex-events--cached-trust "claude-code-ide-codex-events" (key))
(declare-function claude-code-ide-codex-events--result-status "claude-code-ide-codex-events" (result))
(declare-function claude-code-ide-codex-events--start-trust-check "claude-code-ide-codex-events" (key directory))
(declare-function claude-code-ide-codex-events--release-check "claude-code-ide-codex-events" (check))

(defun claude-code-ide-handover--target-available-p (provider)
  "Return non-nil when the CLI of the target PROVIDER is found and can start."
  (let ((detected (ignore-errors (claude-code-ide-provider-call provider 'detect))))
    (and (not (claude-code-ide-provider-unavailable-p detected))
         (plist-get detected :available))))

(defun claude-code-ide-handover--instance-key (instance)
  "Return the working tree of INSTANCE.
See `claude-code-ide-handover--directory-key'."
  (claude-code-ide-handover--directory-key
   (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance))))

(defun claude-code-ide-handover--own-ids (instance)
  "Return the instance ID of INSTANCE, and the ID of its MCP session when known."
  (let ((session (claude-code-ide-instance-session instance)))
    (delq nil (list (claude-code-ide-instance-id instance)
                    (and session (claude-code-ide-mcp-session-session-id session))))))

(defun claude-code-ide-handover--other-instances (key exclude)
  "Return the live instances in the working tree KEY whose IDs are not in EXCLUDE."
  (cl-remove-if-not
   (lambda (other)
     (and (not (member (claude-code-ide-instance-id other) exclude))
          (claude-code-ide-instance-live-p other)
          (equal (claude-code-ide-handover--instance-key other) key)))
   (claude-code-ide-instances)))

(defun claude-code-ide-handover--other-emacs-entries (key exclude)
  "Return the keys of the live registry entries of other Emacs.
Only the entries in the working tree KEY count, and not those in
EXCLUDE.  Such an entry is open or pending, and another Emacs that
still runs owns it (`claude-code-ide-session-registry--other-emacs-p')."
  (delq nil
        (mapcar
         (lambda (entry)
           (let ((entry-key (claude-code-ide-session-registry-entry-key entry)))
             (and (not (member entry-key exclude))
                  (memq (claude-code-ide-session-registry-entry-state entry) '(open pending))
                  (equal (claude-code-ide-handover--directory-key
                          (or (claude-code-ide-session-registry-entry-worktree entry)
                              (claude-code-ide-session-registry-entry-project-dir entry)))
                         key)
                  (claude-code-ide-session-registry--other-emacs-p entry)
                  entry-key)))
         (ignore-errors (claude-code-ide-session-registry--entries)))))

(defun claude-code-ide-handover--live-sessions ()
  "Return the live MCP sessions of this Emacs, or nil without the process file."
  (and (fboundp 'claude-code-ide-process-live-sessions)
       (claude-code-ide-process-live-sessions)))

(defun claude-code-ide-handover--session-directory (session)
  "Return the project folder of the MCP SESSION as a folder name, or nil."
  (let ((directory (ignore-errors (claude-code-ide-mcp-session-project-dir session))))
    (and (stringp directory) (file-name-as-directory (expand-file-name directory)))))

(defun claude-code-ide-handover--other-sessions (key exclude)
  "Return the IDs of the live MCP sessions in the working tree KEY.
The IDs in EXCLUDE do not count.
Only a session without a descriptor counts.  Such a session runs in
this Emacs, for example from an older version of the package.  A
session with a descriptor counts through its instance
\(`claude-code-ide-handover--other-instances')."
  (delq nil
        (mapcar (lambda (session)
                  (let ((id (claude-code-ide-mcp-session-session-id session)))
                    (and (not (member id exclude))
                         (null (claude-code-ide-instance-of-session session))
                         (equal (claude-code-ide-handover--directory-key
                                 (claude-code-ide-handover--session-directory session))
                                key)
                         id)))
                (claude-code-ide-handover--live-sessions))))

(defun claude-code-ide-handover--writers (key exclude)
  "Return the IDs of the live writers in the working tree KEY, without EXCLUDE.
They are the instances of this Emacs, its live MCP sessions without a
descriptor, and the live registry entries of other Emacs.  An instance
or a session in a subfolder of the tree counts too, as long as the
subfolder is no working tree of its own."
  (delete-dups
   (append (mapcar #'claude-code-ide-instance-id
                   (claude-code-ide-handover--other-instances key exclude))
           (claude-code-ide-handover--other-sessions key exclude)
           (claude-code-ide-handover--other-emacs-entries key exclude))))

(defun claude-code-ide-handover--other-writers (instance)
  "Return the IDs of the other live writers in the working tree of INSTANCE.
See `claude-code-ide-handover--writers'."
  (claude-code-ide-handover--writers (claude-code-ide-handover--instance-key instance)
                                     (claude-code-ide-handover--own-ids instance)))

(defun claude-code-ide-handover--run-writers (run)
  "Return the IDs of the live writers in the working tree of RUN.
The source, its MCP session and the target of RUN do not count.  This
works also after the source descriptor is gone, at the document step."
  (claude-code-ide-handover--writers
   (claude-code-ide-handover--run-worktree run)
   (delq nil (list (claude-code-ide-handover--run-source-id run)
                   (claude-code-ide-handover--run-source-session-id run)
                   (claude-code-ide-handover--run-target-id run)))))

(defun claude-code-ide-handover--writer-lines (ids &optional next)
  "Return a line of text for each writer of IDS, for people and for the target.
An ID is a live instance of this Emacs (its label and state), a live
MCP session without a descriptor, or a registry entry of another Emacs
\(its name, provider, key and the process ID of that Emacs).  The line
of an ID in NEXT ends with a note that the current batch hands it over
next."
  (mapcar
   (lambda (id)
     (let ((instance (claude-code-ide-instance-by-id id))
           (entry nil))
       (concat
        (cond
         ((and instance (claude-code-ide-instance-live-p instance))
          (format "%s: %s" (claude-code-ide-handover--instance-label instance)
                  (or (claude-code-ide-control--state-reason (claude-code-ide-control-state-of id))
                      'unknown)))
         ((claude-code-ide-mcp--get-session-by-id id)
          (format "%s: an MCP session without an instance descriptor" id))
         ((setq entry (claude-code-ide-session-registry-entry-of id))
          (format "%s (%s, %s): an instance of the Emacs with process %s"
                  (or (claude-code-ide-session-registry-entry-instance-name entry) id)
                  (claude-code-ide-session-registry-entry-provider entry) id
                  (claude-code-ide-session-registry-entry-emacs-pid entry)))
         (t id))
        (if (member id next) "; handed over by this batch next" ""))))
   ids))

(defun claude-code-ide-handover--codex-trusted-p (directory interactive)
  "Return non-nil when the Codex status hooks are trusted for a start in DIRECTORY.
A target without trusted hooks sends no events, so a handover could
never see its delivery.  INTERACTIVE non-nil asks the user for the
trust when needed (`claude-code-ide-codex-prepare-trust').  Else only
a cached result counts; on a cache miss, a check starts in the
background, so that a later call knows the answer."
  (cond
   ((not (fboundp 'claude-code-ide-codex-events--trust-key)) nil)
   (interactive (and (fboundp 'claude-code-ide-codex-prepare-trust)
                     (claude-code-ide-codex-prepare-trust directory)))
   (t
    (let* ((key (claude-code-ide-codex-events--trust-key))
           (cached (claude-code-ide-codex-events--cached-trust key)))
      (unless cached
        (ignore-errors
          (claude-code-ide-codex-events--release-check
           (claude-code-ide-codex-events--start-trust-check key directory))))
      (eq (claude-code-ide-codex-events--result-status cached) 'trusted)))))

(defconst claude-code-ide-handover--untrusted-message
  "The Codex status hooks are not trusted, so the handover could not see the delivery: M-x claude-code-ide-codex-trust-hooks"
  "The text of a handover to Codex without trusted status hooks.")

(defun claude-code-ide-handover--other-emacs-message (key ids)
  "Return the text for the instances IDS of another Emacs in the working tree KEY."
  (format "Instances of another Emacs run in the working tree %s: %s; stop them there first (only :force hands over anyway)"
          key (string-join (claude-code-ide-handover--writer-lines ids) "; ")))

(defun claude-code-ide-handover--preflight (instance target-provider force allow-others interactive)
  "Return an error result when the handover of INSTANCE cannot start, else nil.
The checks run before anything of the source changes:
- the CLI of TARGET-PROVIDER is found (`target-unavailable');
- no live instance of another Emacs (its registry entry) runs in the
  working tree, unless FORCE (`other-instance');
- no other live instance or MCP session of this Emacs runs in the
  working tree, unless FORCE; ALLOW-OTHERS t allows all of them, and a
  list of IDs allows only those (`other-instance');
- a Codex target has trusted status hooks (`hooks-not-trusted'); with
  INTERACTIVE, the user is asked for the trust first."
  (let* ((id (claude-code-ide-instance-id instance))
         (key (claude-code-ide-handover--instance-key instance))
         (directory (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance))))
    (cond
     ((not (claude-code-ide-handover--target-available-p target-provider))
      (claude-code-ide-handover--error
       'target-unavailable (format "The %s CLI is not available" target-provider) id))
     ((when-let* (((not force))
                  (far (claude-code-ide-handover--other-emacs-entries
                        key (claude-code-ide-handover--own-ids instance))))
        (claude-code-ide-handover--error
         'other-instance (claude-code-ide-handover--other-emacs-message key far) id)))
     ((when-let* (((not (or force (eq allow-others t))))
                  (outside (cl-set-difference (claude-code-ide-handover--other-writers instance)
                                              allow-others :test #'equal)))
        (claude-code-ide-handover--error
         'other-instance
         (format "Other instances run in this working tree: %s; give :allow-others or :force to hand over anyway"
                 (string-join (claude-code-ide-handover--writer-lines outside) "; "))
         id)))
     ((and (eq target-provider 'codex)
           (not (claude-code-ide-handover--codex-trusted-p directory interactive)))
      (claude-code-ide-handover--error
       'hooks-not-trusted claude-code-ide-handover--untrusted-message id)))))

(defun claude-code-ide-handover--missing-feature ()
  "Return the name of a function that a handover needs and that is missing."
  (cl-find-if-not #'fboundp '(claude-code-ide-process-stop-later
                              claude-code-ide-process-worktree-strays
                              claude-code-ide-process-live-sessions
                              claude-code-ide-transcript-handover-document)))

(cl-defun claude-code-ide-handover-session (instance-id target-provider
                                                        &key (method 'fresh) context interrupt
                                                        force allow-others request-id interactive
                                                        (continue nil continue-given) batch-next)
  "Hand the work of INSTANCE-ID to a new conversation of TARGET-PROVIDER.
TARGET-PROVIDER is a provider name, such as `codex'.  The keys:

- METHOD: `fresh' (the default) starts a new conversation with the
  handover document as its first prompt.  `fork' forks the latest
  conversation of TARGET-PROVIDER in the chain, and gives it the
  document.
- CONTEXT: text of the coordinator for the document, or nil.
- INTERRUPT: non-nil to interrupt the source when it is busy.  Without
  it, the handover waits until the source is idle.
- FORCE: non-nil to go on while subagents or background tasks run,
  and while other instances run in the working tree.
- ALLOW-OTHERS: t to go on while other instances or MCP sessions of
  this Emacs run in the working tree; a list of IDs allows only those
  (the ones that a person confirmed).  Unlike FORCE, it
  allows nothing more: subagents, background tasks and an instance of
  another Emacs still refuse the handover.
- REQUEST-ID: a string that the caller chooses.  A second call with a
  known request ID returns the current result of the first one, with
  :duplicate t, and starts nothing.
- INTERACTIVE: non-nil when a person asks in Emacs; then Emacs asks
  that person about stray processes.  A coordinator call gets the
  status `needs-user' instead.
- CONTINUE: t to send the target the continue prompt after the commit,
  nil to send nothing.  Without the key, `claude-code-ide-handover-continue'
  decides, and its value `ask' counts as `always': this function never
  asks.  The interactive question is in `claude-code-ide-handover'.
- BATCH-NEXT: the IDs of the sources that a batch hands over after
  this one; the document marks them (see
  `claude-code-ide-handover-worktree').

The handover runs from timers and returns at once.  A working tree
that another handover holds gives the reason `handover-running', with
the :handover-id of that handover.  The result is the
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
        (append (claude-code-ide-handover--error
                 'handover-running (claude-code-ide-handover--held-message run) instance-id)
                (list :handover-id (claude-code-ide-handover--run-id run)))))
     ((claude-code-ide-handover--preflight instance target-provider force allow-others interactive))
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
           interactive chain
           (if continue-given
               (and continue t)
             (not (eq claude-code-ide-handover-continue 'never)))
           batch-next))))))))

(defun claude-code-ide-handover--begin (instance target-provider method fork-id context
                                                 interrupt force request-id interactive chain
                                                 continue batch-next)
  "Create and save the run of a handover of INSTANCE, and schedule its first step.
TARGET-PROVIDER, METHOD, FORK-ID, CONTEXT, INTERRUPT, FORCE,
REQUEST-ID, INTERACTIVE, CHAIN and BATCH-NEXT are as for
`claude-code-ide-handover-session'.  CONTINUE non-nil sends the
continue prompt at the commit.  Return the result."
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
               :continue continue
               :worktree (claude-code-ide-handover--directory-key directory)
               :directory directory
               :instance-name (and session (claude-code-ide-mcp-session-instance-name session))
               :source-session-id (and session (claude-code-ide-mcp-session-session-id session))
               :role (claude-code-ide-instance-role instance)
               :chain chain
               :batch-next batch-next
               :created-at (claude-code-ide-handover--now))))
    (claude-code-ide-handover--write-context run)
    ;; A first save that waits for the lock is dropped: a refused
    ;; handover leaves no record
    (if (not (claude-code-ide-handover--save run 'drop))
        (progn
          (when-let* ((file (claude-code-ide-handover--run-context-file run)))
            (ignore-errors (delete-file file)))
          (claude-code-ide-handover--error
           'registry-write-failed "The session registry could not save the handover"
           (claude-code-ide-instance-id instance)))
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

(defun claude-code-ide-handover--busy-registry (run)
  "Tell the user that the registry is busy, and run the step of RUN again soon."
  (message "Handover %s: the registry is busy; trying again"
           (claude-code-ide-handover--run-id run))
  (claude-code-ide-handover--schedule run 1)
  nil)

(defun claude-code-ide-handover--enter (run stage)
  "Move RUN to STAGE and save it before the step of STAGE runs.
Return non-nil when the registry holds the stage.  When it does not,
the step of STAGE runs again a moment later, from
`claude-code-ide-handover--step'."
  (setf (claude-code-ide-handover--run-stage run) stage)
  (or (claude-code-ide-handover--save run)
      (claude-code-ide-handover--busy-registry run)))

(defun claude-code-ide-handover--cancel-timers (run)
  "Cancel the step timer and the watch timer of RUN."
  (dolist (timer (list (claude-code-ide-handover--run-timer run)
                       (claude-code-ide-handover--run-watch run)))
    (when (timerp timer) (cancel-timer timer)))
  (setf (claude-code-ide-handover--run-timer run) nil
        (claude-code-ide-handover--run-watch run) nil))

(defun claude-code-ide-handover--run-status-functions (run)
  "Call each function of `claude-code-ide-handover--status-functions' with RUN.
An error of one function gives a message; it changes nothing of RUN,
and the next function runs."
  (run-hook-wrapped
   'claude-code-ide-handover--status-functions
   (lambda (function)
     (condition-case err
         (funcall function run)
       (error (message "Handover %s: the status function %s failed: %s"
                       (claude-code-ide-handover--run-id run) function
                       (error-message-string err))))
     nil)))

(defun claude-code-ide-handover--finish (run status reason &optional text no-save)
  "End RUN with STATUS, REASON and TEXT, save it, and tell the user.
The inbox delivery to the source is no longer held.  NO-SAVE non-nil
ends RUN in this Emacs only, for a source without a registry entry.
After the save succeeded (or with NO-SAVE), the functions of
`claude-code-ide-handover--status-functions' get RUN, once for each
run."
  (claude-code-ide-handover--cancel-timers run)
  (setf (claude-code-ide-handover--run-status run) status
        (claude-code-ide-handover--run-reason run) reason
        (claude-code-ide-handover--run-message run) text)
  (let ((saved (or no-save (claude-code-ide-handover--save run))))
    (claude-code-ide-control-release (claude-code-ide-handover--run-source-id run))
    (message "Handover %s %s%s" (claude-code-ide-handover--run-id run) status
             (if text (concat ": " text) ""))
    (when (and saved (not (claude-code-ide-handover--run-ended run)))
      (setf (claude-code-ide-handover--run-ended run) t)
      (claude-code-ide-handover--run-status-functions run))))

(defun claude-code-ide-handover--guarded (run function &rest args)
  "Call FUNCTION with ARGS for RUN, and turn an error into `needs-user'.
Every step that a timer, a callback or an event runs goes through this
function, so that an error never leaves RUN running with nothing to go
on: the person can try again or cancel."
  (condition-case err
      (apply function args)
    (error
     (claude-code-ide-handover--needs-user
      run 'step-failed
      (format "Stage %s failed: %s" (claude-code-ide-handover--run-stage run)
              (error-message-string err))))))

(defun claude-code-ide-handover--step (run)
  "Run the step of the current stage of RUN.
Each stage has a step, so that a retry after a busy registry, or a
person's retry, always goes on.  An error in a step gives the status
`needs-user', so that a person can try again or cancel."
  (setf (claude-code-ide-handover--run-timer run) nil)
  (when (eq (claude-code-ide-handover--run-status run) 'running)
    (claude-code-ide-handover--guarded run #'claude-code-ide-handover--step-1 run)))

(defun claude-code-ide-handover--step-1 (run)
  "Run the step of the current stage of RUN, without the guard."
  (pcase (claude-code-ide-handover--run-stage run)
    ('requested
     (when (claude-code-ide-handover--enter run 'quiescing)
       (claude-code-ide-handover--quiesce run)))
    ('quiescing (claude-code-ide-handover--quiesce run))
    ('source-stopped (claude-code-ide-handover--stop run))
    ('document-written (claude-code-ide-handover--write-document run))
    ('target-started (claude-code-ide-handover--start-target run))
    ('target-identified
     (when (claude-code-ide-handover--enter run 'target-identified)
       (claude-code-ide-handover--start-watch run)))
    ('delivered
     (when (claude-code-ide-handover--enter run 'delivered)
       (claude-code-ide-handover--commit run)))
    ('committed (claude-code-ide-handover--commit run))
    (_ nil)))

;;; Quiescing

(defun claude-code-ide-handover--interrupt (instance)
  "Send the interrupt key (Escape) to the terminal of INSTANCE."
  (when-let* ((buffer (claude-code-ide-instance-buffer instance))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (claude-code-ide--terminal-send-escape))
    t))

(declare-function claude-code-ide-session-status--drain "claude-code-ide-session-status" ())

(defun claude-code-ide-handover--awaiting-ack-p (run)
  "Return non-nil while the stop of RUN waits for acknowledgements.
That is while the inbox has prompts that it sent to the source and
whose acknowledgement did not come, for at most
`claude-code-ide-handover-ack-wait' seconds.  The status events are
drained first, so that an acknowledgement in a waiting event file
counts."
  (let ((source (claude-code-ide-handover--run-source-id run)))
    (when (cl-some #'claude-code-ide-control--record-sent-at
                   (claude-code-ide-control--pending-records source))
      (when (fboundp 'claude-code-ide-session-status--drain)
        (ignore-errors (claude-code-ide-session-status--drain)))
      (unless (claude-code-ide-handover--run-ack-deadline run)
        (setf (claude-code-ide-handover--run-ack-deadline run)
              (+ (float-time) claude-code-ide-handover-ack-wait)))
      (and (cl-some #'claude-code-ide-control--record-sent-at
                    (claude-code-ide-control--pending-records source))
           (< (float-time) (claude-code-ide-handover--run-ack-deadline run))))))

(defun claude-code-ide-handover--quiesce (run)
  "Wait until the source of RUN is quiet, then go to the stop.
The inbox delivery to the source is held from now on, so that no
queued prompt is sent to it.  With the interrupt key, interrupt a
busy source one time.  Subagents or background tasks cancel the
handover, unless it is forced.  After
`claude-code-ide-handover-quiesce-timeout' the handover is cancelled,
and the source stays current."
  (claude-code-ide-control-hold (claude-code-ide-handover--run-source-id run))
  (let* ((instance (claude-code-ide-instance-by-id (claude-code-ide-handover--run-source-id run)))
         (live (and instance (claude-code-ide-instance-live-p instance)))
         (state (and live (claude-code-ide-instance-state instance))))
    (unless (claude-code-ide-handover--run-deadline run)
      (setf (claude-code-ide-handover--run-deadline run)
            (+ (float-time) claude-code-ide-handover-quiesce-timeout)))
    (cond
     ;; The source ended by itself, or it is quiet, or it is forced
     ((and (or (not live)
               (claude-code-ide-handover--quiet-state-p state)
               (and (claude-code-ide-handover--run-force run)
                    (claude-code-ide-handover--busy-state-p state)))
           (claude-code-ide-handover--awaiting-ack-p run))
      (claude-code-ide-handover--schedule run claude-code-ide-handover-poll-interval))
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

(declare-function claude-code-ide-review-process-ids "claude-code-ide-review" ())

(defun claude-code-ide-handover--review-pids ()
  "Return the process IDs of the review processes that run.
A review command runs in the worktree of its owner, and its result
goes to the target after the handover, so the stop leaves it alone."
  (when (fboundp 'claude-code-ide-review-process-ids)
    (cl-remove-if-not #'integerp
                      (ignore-errors (funcall 'claude-code-ide-review-process-ids)))))

(defun claude-code-ide-handover--other-live-instance-p (stray run)
  "Return non-nil when STRAY is a process of another live instance.
The instances of RUN do not count.
The scan tags such a process with `:instance-id', also its detached
work.  A handover with :allow-others or :force can have another live
instance in its worktree; the end of a
stray must never reach it."
  (let ((id (plist-get stray :instance-id)))
    (and (stringp id)
         (not (member id (list (claude-code-ide-handover--run-source-id run)
                               (claude-code-ide-handover--run-target-id run))))
         (when-let* ((instance (claude-code-ide-instance-by-id id)))
           (claude-code-ide-instance-live-p instance)))))

(defun claude-code-ide-handover--own-session-p (session run)
  "Return non-nil when SESSION is the session of the source or target of RUN."
  (or (equal (claude-code-ide-mcp-session-session-id session)
             (claude-code-ide-handover--run-source-session-id run))
      (when-let* ((instance (claude-code-ide-instance-of-session session)))
        (member (claude-code-ide-instance-id instance)
                (list (claude-code-ide-handover--run-source-id run)
                      (claude-code-ide-handover--run-target-id run))))))

(defun claude-code-ide-handover--other-session-p (stray run)
  "Return non-nil when STRAY is a process of another live MCP session.
The session runs in this Emacs.  The scan tags a process in the CLI
tree of a live session with `:session-id', also for a session without
an instance descriptor (for example one that an older version of the
package started).  The
sessions of the source and the target of RUN do not count, and nor
does a session after its cleanup.  The end of a stray must never
reach another session."
  (when-let* ((id (plist-get stray :session-id))
              ((stringp id))
              (session (claude-code-ide-mcp--get-session-by-id id))
              ((fboundp 'claude-code-ide-process-session-live-p))
              ((claude-code-ide-process-session-live-p session)))
    (not (claude-code-ide-handover--own-session-p session run))))

(defun claude-code-ide-handover--relevant-strays (strays run)
  "Return the STRAYS that can still write in the worktree of RUN.
A process that this Emacs runs itself (`:emacs-process', for example a
language server or a shell buffer) is not a writer of the source.  A
review process (see `claude-code-ide-handover--review-pids') is left
alone too, and so is a process of another live instance (see
`claude-code-ide-handover--other-live-instance-p') or of another live
MCP session (see `claude-code-ide-handover--other-session-p')."
  (let ((reviews (claude-code-ide-handover--review-pids)))
    (cl-remove-if (lambda (stray)
                    (or (plist-get stray :emacs-process)
                        (memql (plist-get stray :pid) reviews)
                        (claude-code-ide-handover--other-live-instance-p stray run)
                        (claude-code-ide-handover--other-session-p stray run)))
                  strays)))

(defun claude-code-ide-handover--with-start (stray)
  "Return STRAY with :start, the start time of its process.
A stray of the scan has the start time of the snapshot that proved its
owner.  When its process ID runs now with another start time, another
process took it: the stray gets that start time, and no longer :own.
A stray without a start time gets the one of now, but never with a
proof of its owner, which holds only for the process of the scan."
  (let ((now (claude-code-ide-session-registry--process-start-time (plist-get stray :pid)))
        (start (plist-get stray :start)))
    (if (and start (or (null now) (claude-code-ide-process--same-start-p start now)))
        stray
      (append (list :start now :own nil) stray))))

(defun claude-code-ide-handover--stop (run)
  "End the source of RUN with its process tree, then check the worktree."
  (let ((instance (claude-code-ide-instance-by-id (claude-code-ide-handover--run-source-id run))))
    (if (and instance (claude-code-ide-instance-live-p instance))
        (claude-code-ide-process-stop-later
         instance
         ;; nil: the soft end of the provider
         :soft-end nil
         :worktree (claude-code-ide-handover--run-worktree run)
         :exclude (claude-code-ide-handover--review-pids)
         :callback (lambda (result)
                     (claude-code-ide-handover--guarded
                      run #'claude-code-ide-handover--after-stop run result)))
      (claude-code-ide-handover--after-stop run (claude-code-ide-handover--scan run)))))

(defconst claude-code-ide-handover--pid-unknown-regexp "process ID of the CLI is unknown"
  "Text of the stop result of a live terminal whose CLI process ID is unknown.
`claude-code-ide-process--empty-result' gives it as the :reason of an
`error' result.")

(defun claude-code-ide-handover--source-live-p (run)
  "Return non-nil when the source of RUN still runs in this Emacs.
The source runs when its descriptor is live and its terminal process
runs; the terminal process is the one that a process-tree stop knows
\(`claude-code-ide-process--terminal-process').  A live descriptor
without a known terminal process counts as running, because nothing
shows that its CLI ended.  The handover never goes past source-stopped,
and never starts a target, while this is non-nil."
  (when-let* ((instance (claude-code-ide-instance-by-id
                         (claude-code-ide-handover--run-source-id run)))
              ((claude-code-ide-instance-live-p instance)))
    (let ((process (and (fboundp 'claude-code-ide-process--terminal-process)
                        (claude-code-ide-process--terminal-process instance nil))))
      (if (processp process) (process-live-p process) t))))

(defun claude-code-ide-handover--source-still-running (run)
  "Make RUN need a person, because its source still runs; return nil."
  (claude-code-ide-handover--needs-user
   run 'source-still-running
   (format "The source %s still runs in this Emacs, so the handover does not go on; end it (kill its terminal buffer), wait, or cancel"
           (claude-code-ide-handover--run-source-id run)))
  nil)

(defun claude-code-ide-handover--source-gone-p (run)
  "Return non-nil when the source of RUN does not run; else make RUN need a person.
See `claude-code-ide-handover--source-live-p'."
  (or (not (claude-code-ide-handover--source-live-p run))
      (claude-code-ide-handover--source-still-running run)))

(defun claude-code-ide-handover--scan (run)
  "Scan the worktree of RUN for stray processes.
Return a result plist like that of `claude-code-ide-process-stop'."
  (condition-case err
      (let ((strays (claude-code-ide-process-worktree-strays
                     (claude-code-ide-handover--run-worktree run)
                     (claude-code-ide-handover--review-pids))))
        (list :status (if strays 'strays 'stopped) :strays strays))
    (error (list :status 'error :reason (error-message-string err)))))

(defun claude-code-ide-handover--after-scan (run)
  "Go on with RUN after a stop or a scan that found no writer.
The continuation of RUN says what comes next: start the target, resume
it, or end a cancel.  Without one, the source stopped, and the
document comes next."
  (let ((next (claude-code-ide-handover--run-continuation run)))
    (if (and (not (eq next 'cancel))
             (not (claude-code-ide-handover--source-gone-p run)))
        nil
      (claude-code-ide-handover--after-scan-1 run next))))

(defun claude-code-ide-handover--after-scan-1 (run next)
  "Do NEXT, the continuation of RUN, after a clean scan; see `--after-scan'."
  (progn
    (setf (claude-code-ide-handover--run-continuation run) nil)
    (if (null next)
        (claude-code-ide-handover--source-stopped run)
      (setf (claude-code-ide-handover--run-strays run) nil
            (claude-code-ide-handover--run-reason run) nil
            (claude-code-ide-handover--run-message run) nil)
      (pcase next
        ('start-target (claude-code-ide-handover--start-target run))
        ('resume-target (claude-code-ide-handover--resume-target run))
        ('cancel (claude-code-ide-handover--cancel-now run))))))

(defun claude-code-ide-handover--scan-then (run next)
  "Scan for writers in the worktree of RUN, then do NEXT when there is none.
NEXT is a continuation (see `claude-code-ide-handover--after-scan').
A target CLI that outlived its Emacs counts as a writer too.  A writer
needs a person, who can end it, wait, or cancel."
  (setf (claude-code-ide-handover--run-continuation run) next
        (claude-code-ide-handover--run-status run) 'running)
  (claude-code-ide-handover--save run)
  (let ((result (claude-code-ide-handover--scan run))
        (survivor (claude-code-ide-handover--target-survivor run)))
    (when (and survivor (not (eq (plist-get result :status) 'error)))
      (setq result (list :status 'strays
                         :strays (cons survivor
                                       (cl-remove (plist-get survivor :pid) (plist-get result :strays)
                                                  :key (lambda (s) (plist-get s :pid)))))))
    (claude-code-ide-handover--after-stop run result)))

(defun claude-code-ide-handover--unknown-strays (run strays)
  "Return the STRAYS of RUN whose owner is unknown; `end' leaves them alone.
While other writers run in the worktree of RUN, a stray is of the
source only when the stop proved it (:own: its CLI tree, a recorded
member with its start time, or a proven recorded group).  Without
other writers, every stray is of the source."
  (when (claude-code-ide-handover--run-writers run)
    (cl-remove-if (lambda (stray) (plist-get stray :own)) strays)))

(defun claude-code-ide-handover--keep-own (stray before)
  "Return STRAY, marked :own when BEFORE has it as :own with the same start time.
A scan after the stop cannot prove the owner again, because the records
of the source end with it; the process ID and its start time keep the
proof of the stop."
  (if (and (not (plist-get stray :own))
           (cl-some (lambda (old)
                      (and (plist-get old :own)
                           (eql (plist-get old :pid) (plist-get stray :pid))
                           (claude-code-ide-process--same-start-p (plist-get old :start)
                                                                  (plist-get stray :start))))
                    before))
      (append stray (list :own t))
    stray))

(defun claude-code-ide-handover--strays-note (run strays)
  "Return the note about the STRAYS of RUN whose owner is unknown.
Without such strays, return the empty text."
  (if-let* ((unknown (claude-code-ide-handover--unknown-strays run strays)))
      (format "; %d with owner unknown (other sessions run here): end leaves them alone, check them by hand"
              (length unknown))
    ""))

(defun claude-code-ide-handover--after-stop (run result)
  "Go on with RUN after the stop or the scan that gave RESULT.
Strays, a source that survived, and a failed scan need a person.  Each
stray gets the start time of its process now, so that a later signal
reaches only that process, and keeps the proof of its owner (see
`claude-code-ide-handover--keep-own')."
  (when (eq (claude-code-ide-handover--run-status run) 'running)
    (let* ((before (claude-code-ide-handover--run-strays run))
           (strays (mapcar (lambda (stray)
                             (claude-code-ide-handover--keep-own
                              (claude-code-ide-handover--with-start stray) before))
                           (claude-code-ide-handover--relevant-strays (plist-get result :strays) run))))
      (pcase (plist-get result :status)
        ((or 'stopped (and 'strays (guard (null strays))))
         (claude-code-ide-handover--after-scan run))
        ('strays
         (claude-code-ide-handover--needs-user
          run 'strays (concat "Processes still run in the worktree"
                              (claude-code-ide-handover--strays-note run strays))
          strays))
        ('timeout
         (claude-code-ide-handover--needs-user
          run 'source-did-not-stop (concat "The source or its processes survived SIGKILL"
                                           (claude-code-ide-handover--strays-note run strays))
          strays))
        ((and 'error (guard (string-match-p claude-code-ide-handover--pid-unknown-regexp
                                            (format "%s" (plist-get result :reason)))))
         (claude-code-ide-handover--needs-user
          run 'source-pid-unknown
          (format "The stop could not end or check the source %s, because the process ID of its CLI is unknown: the source CLI may still run.  End it (kill its terminal buffer), wait, or cancel"
                  (claude-code-ide-handover--run-source-id run))))
        ((guard (claude-code-ide-handover--source-live-p run))
         (claude-code-ide-handover--source-still-running run))
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
  (claude-code-ide-handover--cancel-timers run)
  (setf (claude-code-ide-handover--run-status run) 'needs-user
        (claude-code-ide-handover--run-reason run) reason
        (claude-code-ide-handover--run-message run) text
        (claude-code-ide-handover--run-strays run) strays)
  (claude-code-ide-handover--save run)
  (claude-code-ide-handover--run-status-functions run)
  (if (claude-code-ide-handover--run-interactive run)
      (run-at-time 0 nil #'claude-code-ide-handover--ask run)
    (message "Handover %s needs you: %s.  M-x claude-code-ide-handover-resolve"
             (claude-code-ide-handover--run-id run) text)))

(defun claude-code-ide-handover--choices (run)
  "Return the choices of a person for RUN, as (KEY ACTION DESCRIPTION).
After the commit saved the chain of the target, the choices are retry
and skip for every reason: the chain names the target, so a cancel
would stop the current instance."
  (if (claude-code-ide-handover--sync-chain-saved run)
      '((?r retry "finish the commit again (it sends a continue prompt that is due)")
        (?s skip "finish the handover without the continue prompt"))
    (claude-code-ide-handover--choices-before-chain run)))

(defun claude-code-ide-handover--choices-before-chain (run)
  "Return the choices of a person for RUN before the chain of its target is saved."
  (pcase (claude-code-ide-handover--run-reason run)
    ((or 'strays 'source-did-not-stop)
     `((?e end ,(if (claude-code-ide-handover--unknown-strays run (claude-code-ide-handover--run-strays run))
                    "end only the strays of the source: SIGTERM, then SIGKILL; those with owner unknown stay, check them by hand"
                  "end them: SIGTERM, then SIGKILL"))
       (?w wait "wait, then check again")
       (?c cancel "cancel the handover")))
    ((or 'source-pid-unknown 'source-still-running)
     '((?e end "end the source: kill its terminal buffer, then check the worktree")
       (?w wait "wait, then try the step again")
       (?c cancel "cancel the handover")))
    ('scan-failed
     '((?w wait "check again")
       (?g go "go on without the check")
       (?c cancel "cancel the handover")))
    ('no-delivery
     '((?w wait "wait again for the delivery")
       (?c cancel "cancel the handover and stop the target")))
    ('target-exited
     '((?r retry "start the target again")
       (?c cancel "cancel the handover")))
    ('registry-entry-missing
     '((?c cancel "cancel the handover")))
    (_
     '((?r retry "try the stage again")
       (?c cancel "cancel the handover")))))

(defun claude-code-ide-handover--describe-strays (strays &optional unknown)
  "Return a text that lists STRAYS: process ID, command and folder.
A stray in UNKNOWN gets the note \"owner unknown\"."
  (mapconcat (lambda (stray)
               (format "  %s  %s  (in %s)%s"
                       (plist-get stray :pid)
                       (or (plist-get stray :command) "?")
                       (or (plist-get stray :cwd) "?")
                       (if (memq stray unknown) "  owner unknown" "")))
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
                                (concat ":\n" (claude-code-ide-handover--describe-strays
                                               strays (claude-code-ide-handover--unknown-strays run strays)))
                              ""))
                    (mapcar (lambda (choice)
                              (list (nth 0 choice) (symbol-name (nth 1 choice)) (nth 2 choice)))
                            choices))))
      (claude-code-ide-handover-resolve (claude-code-ide-handover--run-id run)
                                        (nth 1 (assq (car answer) choices))))))

(defun claude-code-ide-handover--stray-alive-p (stray)
  "Return non-nil when the process of STRAY is still the process of the scan.
Its process ID must run with the start time that the scan recorded,
within the tolerance of `claude-code-ide-session-registry--same-start-p'.
An unknown start time, at the scan or now, never matches."
  (let ((recorded (plist-get stray :start)))
    (and (numberp recorded)
         (integerp (plist-get stray :pid))
         (claude-code-ide-session-registry--same-start-p (plist-get stray :pid) recorded)
         t)))

(defun claude-code-ide-handover--end-strays (strays signal)
  "Send SIGNAL to each of STRAYS that is still the process of the scan."
  (dolist (stray strays)
    (when (claude-code-ide-handover--stray-alive-p stray)
      (ignore-errors (signal-process (plist-get stray :pid) signal)))))

(defun claude-code-ide-handover--rescan (run &optional then seconds)
  "Scan the worktree of RUN again after `claude-code-ide-handover-stray-wait'.
THEN, when given, runs first, with the strays of RUN.  SECONDS, when
given, is the wait in place of `claude-code-ide-handover-stray-wait'."
  (setf (claude-code-ide-handover--run-status run) 'running)
  (claude-code-ide-handover--save run)
  (setf (claude-code-ide-handover--run-timer run)
        (run-at-time (or seconds claude-code-ide-handover-stray-wait) nil
                     (lambda ()
                       (claude-code-ide-handover--guarded
                        run (lambda ()
                              (when then (funcall then (claude-code-ide-handover--run-strays run)))
                              (claude-code-ide-handover--after-stop
                               run (claude-code-ide-handover--scan run))))))))

(defun claude-code-ide-handover--read-unfinished (prompt)
  "Read the ID of an unfinished handover with PROMPT."
  (let ((ids (delete-dups
              (mapcar #'claude-code-ide-handover--run-id
                      (cl-remove-if-not #'claude-code-ide-handover--unfinished-p
                                        (append (hash-table-values claude-code-ide-handover--runs)
                                                (claude-code-ide-handover--registry-runs)))))))
    (unless ids (user-error "No handover is unfinished"))
    (if (cdr ids) (completing-read prompt ids nil t) (car ids))))

(defun claude-code-ide-handover--resume (run)
  "Set RUN running again, without a reason, and save it."
  (setf (claude-code-ide-handover--run-status run) 'running
        (claude-code-ide-handover--run-reason run) nil
        (claude-code-ide-handover--run-message run) nil
        (claude-code-ide-handover--run-missing-entry run) nil)
  (claude-code-ide-handover--save run))

(defun claude-code-ide-handover--adopt (handover-id)
  "Take the handover HANDOVER-ID of the registry into this Emacs; return its run.
A handover of an Emacs that ended is claimed and recovered.  When
another live Emacs owns it, a question names that owner, and only a
yes takes it over (a forced claim)."
  (let ((run (claude-code-ide-handover--find handover-id)))
    (cond
     ((null run) (user-error "No handover %s" handover-id))
     ((not (claude-code-ide-handover--unfinished-p run))
      (user-error "Handover %s is %s" handover-id (claude-code-ide-handover--run-status run)))
     ((and (eq (claude-code-ide-handover--run-owner run) 'other)
           (not (yes-or-no-p
                 (format "Handover %s belongs to the Emacs with process %s on %s, which seems to run.  Take it over? "
                         handover-id (claude-code-ide-handover--run-owner-pid run)
                         (or (claude-code-ide-handover--run-owner-host run) "another host")))))
      (user-error "Handover %s stays with its Emacs" handover-id))
     ((not (claude-code-ide-handover--claim run (eq (claude-code-ide-handover--run-owner run) 'other)))
      (user-error "Handover %s could not be claimed" handover-id))
     (t
      (claude-code-ide-handover--recover-claimed run t)
      run))))

(defun claude-code-ide-handover-resolve (handover-id &optional action)
  "Answer the question of the handover HANDOVER-ID with ACTION.
ACTION is one of the choices that the handover offers:
- `end': end the stray processes (SIGTERM, then SIGKILL), then check again.
- `wait': check the strays again after `claude-code-ide-handover-stray-wait'
  seconds, or wait again for the delivery of the document (after a look
  at the transcript of the target).
- `go': go on although the process check failed.
- `retry': run the stage again; a target that runs is taken up again,
  and a target that ended starts again after a scan of the worktree.
- `skip': finish a committed handover without its continue prompt.
- `cancel': cancel the handover; see `claude-code-ide-handover-cancel'.
A handover that this Emacs does not run is taken over first (see
`claude-code-ide-handover--adopt'; another live Emacs needs a yes).
Interactively, choose the handover and the action."
  (interactive (list (claude-code-ide-handover--read-unfinished "Handover: ") nil))
  (let ((run (or (gethash handover-id claude-code-ide-handover--runs)
                 (claude-code-ide-handover--adopt handover-id))))
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
        ('skip
         ;; Only the continue prompt goes; every other step of the
         ;; commit runs as for retry
         (setf (claude-code-ide-handover--run-continue run) nil)
         (claude-code-ide-handover--resume run)
         (claude-code-ide-handover--guarded run #'claude-code-ide-handover--commit run)
         ;; The record of the source cannot be saved (its entry is
         ;; gone): end the run in this Emacs, but only after the inbox
         ;; of the source moved to the target.  A missing target entry
         ;; stays a needs-user that the record holds too
         (when (and (claude-code-ide-handover--unfinished-p run)
                    (eq (claude-code-ide-handover--run-reason run) 'registry-entry-missing)
                    (eq (claude-code-ide-handover--run-missing-entry run) 'source))
           (condition-case err
               (progn
                 (ignore-errors
                   (claude-code-ide-handover--acknowledge-from-transcript
                    run (claude-code-ide-handover--run-source-id run)))
                 (claude-code-ide-control-move-inbox (claude-code-ide-handover--run-source-id run)
                                                     (claude-code-ide-handover--run-target-id run)
                                                     (claude-code-ide-handover--run-id run))
                 (claude-code-ide-handover--finish
                  run 'committed nil
                  "in this Emacs only; the registry has no entry of the source to save it in" t))
             (error
              ;; The registry cannot hold the text; keep it in this Emacs
              (setf (claude-code-ide-handover--run-message run)
                    (format "The registry has no entry of the source, and the inbox of the source did not move to the target: %s.  Skip again after the move can work"
                            (error-message-string err)))
              (message "Handover %s needs you: %s" (claude-code-ide-handover--run-id run)
                       (claude-code-ide-handover--run-message run))))))
        ('cancel
         (if (eq (claude-code-ide-handover--run-continuation run) 'cancel)
             ;; The person leaves the target process running
             (claude-code-ide-handover--cancel-now run)
           (claude-code-ide-handover-cancel handover-id)))
        ((and 'wait (guard (memq (claude-code-ide-handover--run-reason run)
                                 '(source-pid-unknown source-still-running))))
         ;; Try the stop again later; a recovery scans again, with its
         ;; continuation
         (if (claude-code-ide-handover--run-continuation run)
             (claude-code-ide-handover--rescan run)
           (claude-code-ide-handover--resume run)
           (claude-code-ide-handover--schedule run claude-code-ide-handover-stray-wait)))
        ((and 'end (guard (memq (claude-code-ide-handover--run-reason run)
                                '(source-pid-unknown source-still-running))))
         ;; As `claude-code-ide-control-stop': the stop of the provider
         ;; kills the terminal buffer, which ends the CLI.  With the
         ;; kept buffers, the CLI ends softly from timers, so the scan
         ;; waits at least until the limit of that soft stop
         (let ((stop (claude-code-ide-control-stop (claude-code-ide-handover--run-source-id run))))
           (when (eq (plist-get stop :status) 'error)
             (message "Handover %s: the stop of the source gave %s"
                      (claude-code-ide-handover--run-id run)
                      (or (plist-get stop :message) (plist-get stop :reason)))))
         (claude-code-ide-handover--rescan
          run nil (max claude-code-ide-handover-stray-wait
                       (if (fboundp 'claude-code-ide--soft-stop-limit)
                           (claude-code-ide--soft-stop-limit)
                         0))))
        ('wait
         (if (eq (claude-code-ide-handover--run-reason run) 'no-delivery)
             (progn
               (claude-code-ide-handover--resume run)
               (if (claude-code-ide-handover--target-delivered-p run)
                   (claude-code-ide-handover--delivered run)
                 (claude-code-ide-handover--start-watch run)))
           (claude-code-ide-handover--rescan run)))
        ('end
         (let* ((all (claude-code-ide-handover--run-strays run))
                (unknown (claude-code-ide-handover--unknown-strays run all))
                (strays (cl-remove-if (lambda (stray) (memq stray unknown)) all)))
           (claude-code-ide-handover--end-strays strays 'SIGTERM)
           (claude-code-ide-handover--rescan
            run (lambda (_) (claude-code-ide-handover--end-strays strays 'SIGKILL)))))
        ('go
         (setf (claude-code-ide-handover--run-status run) 'running)
         (claude-code-ide-handover--after-scan run))
        ('retry
         (cond
          ;; After the chain save (for example a continue prompt that
          ;; failed): commit again, which sends a prompt that is due
          ;; with the same request ID
          ((claude-code-ide-handover--sync-chain-saved run)
           (claude-code-ide-handover--resume run)
           (claude-code-ide-handover--guarded run #'claude-code-ide-handover--commit run))
          ;; A target that runs and waits for its document: take it up
          ;; again, never a second start.  From the stage delivered on,
          ;; the step of the stage (the commit) runs again, below
          ((and (not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                       'target-started))
                (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                  'delivered)
                (claude-code-ide-handover--live-target run))
           (claude-code-ide-handover--resume run)
           (claude-code-ide-handover--check-identified run)
           (claude-code-ide-handover--start-watch run))
          ;; A target that ended: a new launch of the same target ID,
          ;; with the same document, after a scan for writers
          ((eq (claude-code-ide-handover--run-reason run) 'target-exited)
           (setf (claude-code-ide-handover--run-stage run) 'target-started
                 (claude-code-ide-handover--run-target-native-id run) nil
                 (claude-code-ide-handover--run-reason run) nil
                 (claude-code-ide-handover--run-message run) nil)
           (claude-code-ide-handover--scan-then run 'start-target))
          (t
           (claude-code-ide-handover--resume run)
           (claude-code-ide-handover--schedule run 0)))))
      (claude-code-ide-handover--result run))))

(defun claude-code-ide-handover--live-target (run)
  "Return the descriptor of the target of RUN when it runs, else nil."
  (when-let* ((id (claude-code-ide-handover--run-target-id run))
              (instance (claude-code-ide-instance-by-id id))
              ((claude-code-ide-instance-live-p instance)))
    instance))

(defun claude-code-ide-handover--claim (run &optional force)
  "Make this Emacs the owner of RUN in the registry.  Return non-nil on success.
The claim fails when another Emacs that still runs owns RUN, unless
FORCE is non-nil (a person decided)."
  (and (consp (claude-code-ide-session-registry-claim-handover
               (claude-code-ide-handover--run-source-id run)
               (claude-code-ide-handover--run-id run)
               force))
       (setf (claude-code-ide-handover--run-owner run) 'self)))

(defun claude-code-ide-handover--drop-target (run)
  "Stop the target of RUN when it runs in this Emacs, and archive its entry.
A cancelled handover leaves no target that a restore could start.  A
target process that outlived its Emacs is not ended here: the cancel
shows it to a person first (see `claude-code-ide-handover-cancel')."
  (when-let* ((instance (claude-code-ide-handover--live-target run)))
    (if (fboundp 'claude-code-ide-process-stop)
        (claude-code-ide-process-stop instance)
      (claude-code-ide-provider-call (claude-code-ide-instance-provider instance) 'stop instance)))
  (when-let* ((id (claude-code-ide-handover--run-target-id run))
              ((claude-code-ide-session-registry-entry-of id)))
    (claude-code-ide-session-registry--submit
     "archived" (claude-code-ide-session-registry--change-archived id))))

(defun claude-code-ide-handover--cancel-now (run)
  "End RUN as cancelled: stop its target in this Emacs and archive its entry."
  (unless (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                            'target-started)
    (claude-code-ide-handover--drop-target run))
  (claude-code-ide-handover--finish
   run 'cancelled 'user-cancelled
   (cond
    ((claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                       'source-stopped)
     "the source stays current")
    ;; The stop could not end it, or it runs again after a restore
    ((claude-code-ide-handover--source-live-p run)
     "the source still runs in this Emacs, and stays current")
    (t "the source is stopped; M-x claude-code-ide-reopen-session starts it again")))
  (claude-code-ide-handover--result run))

(defun claude-code-ide-handover-cancel (handover-id)
  "Cancel the unfinished handover HANDOVER-ID.
A running handover whose target runs cannot be cancelled.  One that
needs a person can: its target is stopped and its registry entry
archived.  A target process that outlived its Emacs is shown to the
person first, like a stray: end it, wait, or cancel and leave it.  A
cancel before the stop keeps the source current; after the stop, the
source stays stopped.  A handover that another live Emacs runs is
refused; a handover of an Emacs that ended is claimed first."
  (interactive (list (claude-code-ide-handover--read-unfinished "Cancel handover: ")))
  (let ((run (claude-code-ide-handover--find handover-id)))
    (cond
     ((null run) (user-error "No handover %s" handover-id))
     ((not (claude-code-ide-handover--unfinished-p run))
      (user-error "Handover %s is %s already" handover-id (claude-code-ide-handover--run-status run)))
     ;; The chain names the target already; a cancel would stop it.
     ;; Before the chain save (for example a missing target entry), a
     ;; cancel still works
     ((claude-code-ide-handover--sync-chain-saved run)
      (user-error "Handover %s is committed (the chain names its target); it cannot be cancelled"
                  handover-id))
     ((and (eq (claude-code-ide-handover--run-status run) 'running)
           (claude-code-ide-handover--live-target run))
      (user-error "The target of handover %s runs already" handover-id))
     ((and (not (gethash (claude-code-ide-handover--run-id run) claude-code-ide-handover--runs))
           (not (claude-code-ide-handover--claim run)))
      (user-error "Another Emacs runs handover %s" handover-id))
     (t
      (puthash (claude-code-ide-handover--run-id run) run claude-code-ide-handover--runs)
      (if-let* (((not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                        'target-started)))
                (survivor (claude-code-ide-handover--target-survivor run)))
          (progn
            (setf (claude-code-ide-handover--run-continuation run) 'cancel)
            (claude-code-ide-handover--needs-user
             run 'strays "The target of the handover still runs; end it before the cancel"
             (list survivor))
            (claude-code-ide-handover--result run))
        (claude-code-ide-handover--cancel-now run))))))

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
   :session-server claude-code-ide-handover-session-server-detection
   :others (claude-code-ide-handover--writer-lines (claude-code-ide-handover--run-writers run)
                                                   (claude-code-ide-handover--run-batch-next run))))

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
    (when (and (claude-code-ide-handover--source-gone-p run)
               (claude-code-ide-handover--enter run 'target-started))
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

(defun claude-code-ide-handover-start-prompt (run)
  "Return the first prompt of the target of RUN: a pointer to its document.
The document itself never goes on the command line, which has a size
limit and which `ps' shows.  The first line is the marker of the
handover, so that its `UserPromptSubmit' is the delivery, and the
transcript reader treats the turn as the start of a leg.  The second
line names the document file; `claude-code-ide-transcript-document-file'
reads it, so keep the two in step.  Signal an error when the document
file is missing or does not have its hash."
  (unless (claude-code-ide-handover--document run)
    (error "The handover document %s is missing or changed"
           (claude-code-ide-handover--run-document run)))
  (format "%s\nRead the handover document at %s fully, and follow its instructions.\n- State summary file: `%s`"
          (format claude-code-ide-transcript--marker-format (claude-code-ide-handover--run-id run))
          (claude-code-ide-handover--run-document run)
          (claude-code-ide-handover--run-summary-file run)))

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

(defun claude-code-ide-handover--fresh-session-flags (run)
  "Return the flags that start the Claude Code target of RUN with its ID, or nil.
The ID is the known native ID.  A fresh start of an unsaved target (see
`claude-code-ide-handover-unsaved-target') keeps the target's native
ID: --session-id comes after the user's flags.  A first start has no
native ID yet, a fork gets a new one from the CLI, and another provider
chooses its own; they get nil."
  (let ((native (claude-code-ide-handover--run-target-native-id run)))
    (when (and (eq (claude-code-ide-handover--run-target-provider run) 'claude)
               (stringp native)
               (not (claude-code-ide-handover--run-fork-id run)))
      (string-trim (concat (or claude-code-ide-cli-extra-flags "") " --session-id " native)))))

(defun claude-code-ide-handover--start-spec (run prompt)
  "Return the start spec of the target of RUN, with PROMPT as its first prompt.
A Claude Code target with a known native ID gets it again; see
`claude-code-ide-handover--fresh-session-flags'."
  (let* ((id (claude-code-ide-handover--run-target-id run))
         (entry (claude-code-ide-session-registry-entry-of id))
         (last (max (or (claude-code-ide-instance-current-generation id) 0)
                    (or (and entry (claude-code-ide-session-registry-entry-generation entry)) 0))))
    (claude-code-ide-start-spec-create
     :directory (claude-code-ide-handover--run-directory run)
     :instance-name (claude-code-ide-handover--run-instance-name run)
     :prompt prompt
     :provider (claude-code-ide-handover--run-target-provider run)
     :extra-flags (claude-code-ide-handover--fresh-session-flags run)
     :instance-id id
     ;; A start of an instance ID that has a record names its generation
     :last-generation (and (> last 0) last)
     :role (claude-code-ide-handover--run-role run)
     :resume-id (claude-code-ide-handover--run-fork-id run)
     :fork (and (claude-code-ide-handover--run-fork-id run) t)
     ;; Only a handover that a person started may ask, for example
     ;; whether to trust the Codex status hooks of the target
     :interactive (and (claude-code-ide-handover--run-interactive run) t))))

(defun claude-code-ide-handover--save-pending-chain (run)
  "Save the chain of the target of RUN, with its leg pending.
While the registry is busy, try again every second, as long as the
handover runs and is not committed.  The pending leg keeps the target
from a plain restore."
  (unless (or (claude-code-ide-handover--save-chain
               run (claude-code-ide-handover--target-chain run 'pending))
              (not (claude-code-ide-handover--unfinished-p run)))
    (run-at-time 1 nil
                 (lambda ()
                   (when (and (eq (claude-code-ide-handover--run-status run) 'running)
                              (claude-code-ide-handover--stage<
                               (claude-code-ide-handover--run-stage run) 'committed))
                     (claude-code-ide-handover--guarded
                      run #'claude-code-ide-handover--save-pending-chain run))))))

(defun claude-code-ide-handover--start-target (run)
  "Start the target of RUN with the pointer to the document as its first prompt.
The target ID is saved in the registry before the start; while the
registry is busy, the start waits.  A source that still runs in this
Emacs stops the start: see `claude-code-ide-handover--source-gone-p'."
  (when (claude-code-ide-handover--source-gone-p run)
    (claude-code-ide-handover--start-target-1 run)))

(defun claude-code-ide-handover--start-target-1 (run)
  "Start the target of RUN; see `claude-code-ide-handover--start-target'."
  (unless (claude-code-ide-handover--run-target-id run)
    (setf (claude-code-ide-handover--run-target-id run) (claude-code-ide-instance-new-id)))
  (if (not (claude-code-ide-handover--save run))
      (claude-code-ide-handover--busy-registry run)
    (let ((prompt (claude-code-ide-handover-start-prompt run))
          (claude-code-ide-handover--allowed (claude-code-ide-handover--run-id run))
          ;; The target takes the window of the copy of its source
          (claude-code-ide--replace-copy-of (claude-code-ide-handover--run-source-id run)))
      (condition-case err
          (claude-code-ide--start-session nil nil (claude-code-ide-handover--start-spec run prompt))
        ((error quit)
         (claude-code-ide-handover--needs-user
          run 'start-failed (format "The target did not start: %s" (error-message-string err)))))
      (when (eq (claude-code-ide-handover--run-status run) 'running)
        (claude-code-ide-handover--save-pending-chain run)
        (claude-code-ide-handover--start-watch run)
        (claude-code-ide-handover--check-identified run)))))

(defun claude-code-ide-handover--start-watch (run)
  "Watch the target of RUN until it gets the document.
After `claude-code-ide-handover-delivery-timeout' seconds without the
delivery, or when the target ends before it, the handover needs a
person."
  (setf (claude-code-ide-handover--run-delivery-deadline run)
        (+ (float-time) claude-code-ide-handover-delivery-timeout))
  (claude-code-ide-handover--schedule-watch run))

(defun claude-code-ide-handover--schedule-watch (run)
  "Check the target of RUN again after `claude-code-ide-handover-watch-interval'."
  (when (timerp (claude-code-ide-handover--run-watch run))
    (cancel-timer (claude-code-ide-handover--run-watch run)))
  (setf (claude-code-ide-handover--run-watch run)
        (run-at-time claude-code-ide-handover-watch-interval nil
                     #'claude-code-ide-handover--guarded run #'claude-code-ide-handover--watch run)))

(defun claude-code-ide-handover--watch (run)
  "Check that the target of RUN runs and gets its document in time.
Before it gives up, it looks for the marker in the transcript of the
target: an event can be lost, and the transcript tells."
  (setf (claude-code-ide-handover--run-watch run) nil)
  (when (and (eq (claude-code-ide-handover--run-status run) 'running)
             (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                               'delivered))
    (let ((live (claude-code-ide-handover--live-target run))
          (late (> (float-time) (or (claude-code-ide-handover--run-delivery-deadline run) 0))))
      (cond
       ((and (or (not live) late) (claude-code-ide-handover--target-delivered-p run))
        (claude-code-ide-handover--delivered run))
       ((not live)
        (claude-code-ide-handover--needs-user
         run 'target-exited "The target ended before it got the handover document"))
       (late
        (claude-code-ide-handover--needs-user
         run 'no-delivery
         (format "The target did not get the handover document in %s seconds"
                 claude-code-ide-handover-delivery-timeout)))
       (t (claude-code-ide-handover--schedule-watch run))))))

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
  (when (and (claude-code-ide-handover--unfinished-p run)
             (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                               'target-identified))
    (setf (claude-code-ide-handover--run-target-native-id run) native-id)
    (claude-code-ide-handover--enter run 'target-identified)))

(defun claude-code-ide-handover--delivered (run)
  "Record that the target of RUN received the document, and commit.
This holds in every unfinished status: a delivery that comes while the
run waits for a person ends the wait."
  (when (and (claude-code-ide-handover--unfinished-p run)
             (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run) 'delivered))
    (when (eq (claude-code-ide-handover--run-status run) 'needs-user)
      (claude-code-ide-handover--resume run))
    (when (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                            'target-identified)
      (claude-code-ide-handover--check-identified run))
    (when (claude-code-ide-handover--enter run 'delivered)
      (claude-code-ide-handover--commit run))))

(defun claude-code-ide-handover--commit (run)
  "Make the target of RUN the current instance of the chain.
The steps, each idempotent, so that a recovery or a retry runs them
again after a crash or a failure:
1. Enter the stage committed (saved).
2. Save the final chain of the target, then mark it in the record
   (`chain-saved', saved).  From here on, the handover cannot be
   cancelled: the chain names the target.
3. Move the inbox of the source to the target.
4. Send the continue prompt, when it is due (see
   `claude-code-ide-handover--send-continue'); its acceptance is saved
   at once (`continue-sent').
5. Finish: the status committed (saved).
A busy registry runs the step again a moment later."
  (when (claude-code-ide-handover--enter run 'committed)
    (let ((source (claude-code-ide-handover--run-source-id run))
          (target (claude-code-ide-handover--run-target-id run)))
      (if (not (claude-code-ide-handover--save-chain run (claude-code-ide-handover--target-chain run)))
          (when (eq (claude-code-ide-handover--run-status run) 'running)
            (claude-code-ide-handover--busy-registry run))
        (when (and (claude-code-ide-handover--mark-chain-saved run)
                   ;; Queued prompts and review results go to the new
                   ;; instance; the run never finishes without them
                   (claude-code-ide-handover--move-inbox run source target))
          ;; Before the final save, so that a crash in between sends it
          ;; at the recovery; the fixed request ID sends it only once.
          ;; A prompt that the inbox does not take keeps the run
          ;; unfinished
          (pcase (claude-code-ide-handover--send-continue run)
            ('nil
             (claude-code-ide-handover--finish run 'committed nil
                                               (format "%s %s -> %s %s"
                                                       (claude-code-ide-handover--run-source-provider run)
                                                       source
                                                       (claude-code-ide-handover--run-target-provider run)
                                                       target)))
            ;; The registry was busy: the step runs again soon
            ('busy nil)
            (failure
             (claude-code-ide-handover--needs-user
              run 'continue-failed
              (format "The handover is committed, but the continue prompt did not reach the inbox of the target %s: %s.  Retry sends it again; skip finishes without it"
                      target failure)))))))))

(defun claude-code-ide-handover--sync-chain-saved (run)
  "Set the `chain-saved' mark of RUN from the saved chain of its target.
The chain save of the target and the save of the mark in the source
record are two writes; a crash between them leaves the mark off, while
the target has its final chain already.  So the mark is also on when
the chain of the target has a leg of this handover that is not
pending.  The cancel, the choices and the recovery call this first.
Return the mark."
  (or (claude-code-ide-handover--run-chain-saved run)
      (when-let* ((target (claude-code-ide-handover--run-target-id run))
                  (entry (ignore-errors (claude-code-ide-session-registry-entry-of target)))
                  ((cl-some (lambda (leg)
                              (and (equal (plist-get leg :handover-id)
                                          (claude-code-ide-handover--run-id run))
                                   (not (plist-get leg :pending))))
                            (claude-code-ide-session-registry-entry-legs entry))))
        (setf (claude-code-ide-handover--run-chain-saved run) t))))

(defun claude-code-ide-handover--mark-chain-saved (run)
  "Record in RUN that the chain of its target is saved, and save RUN.
Return non-nil when the registry holds it.  When the registry is busy,
the step runs again a moment later, as for the stages.  A second call
saves again, which does no harm."
  (setf (claude-code-ide-handover--run-chain-saved run) t)
  (or (claude-code-ide-handover--save run)
      (claude-code-ide-handover--busy-registry run)))

(defun claude-code-ide-handover--iso-seconds (time)
  "Return the ISO 8601 TIME as seconds since the epoch, or nil."
  (when (stringp time)
    (ignore-errors (float-time (parse-iso8601-time-string time)))))

(defun claude-code-ide-handover--acknowledge-from-transcript (run source)
  "Mark as delivered the sent prompts of SOURCE that its transcript holds.
The transcript is the source transcript of RUN.
The inbox sent such a prompt to SOURCE, and its acknowledgement did not
come.  When the transcript has a user turn with the same text hash at
or after the send (within one second), the source got it, and the
handover document holds it: it must not go to the target again.  A
prompt without such a turn moves, with its note.  A transcript that
cannot be read marks nothing."
  (when-let* ((sent (cl-remove-if-not #'claude-code-ide-control--record-sent-at
                                      (claude-code-ide-control--pending-records source)))
              (file (plist-get (claude-code-ide-handover--run-source-leg run) :transcript))
              ((stringp file))
              (turns (ignore-errors (claude-code-ide-transcript-read file))))
    (dolist (record sent)
      (when-let* ((since (claude-code-ide-handover--iso-seconds
                          (claude-code-ide-control--record-sent-at record)))
                  (turn (cl-find-if
                         (lambda (turn)
                           (let ((time (claude-code-ide-handover--iso-seconds (plist-get turn :time))))
                             (and (eq (plist-get turn :role) 'user)
                                  (stringp (plist-get turn :text))
                                  time (>= time (- since 1))
                                  (equal (claude-code-ide-control-text-hash (plist-get turn :text))
                                         (claude-code-ide-control--record-text-hash record)))))
                         turns)))
        (claude-code-ide-control--acknowledge
         (list :instance-id source :event 'prompt-submit
               :data (list (cons 'prompt (plist-get turn :text)))))))))

(defun claude-code-ide-handover--move-inbox (run source target)
  "Move the inbox of SOURCE to TARGET for RUN.  Return non-nil when it moved.
A sent prompt that the source transcript holds is marked delivered
first, and does not move (see
`claude-code-ide-handover--acknowledge-from-transcript').
A failure gives `needs-user' with the reason `step-failed', and a
message that names the move: the queued prompts and review results of
the source must reach the target, so the run does not finish without
the move.  The move is
idempotent, so retry and skip simply move again."
  (condition-case err
      (progn
        (ignore-errors (claude-code-ide-handover--acknowledge-from-transcript run source))
        (claude-code-ide-control-move-inbox source target (claude-code-ide-handover--run-id run))
        t)
    (error
     (claude-code-ide-handover--needs-user
      run 'step-failed
      (format "Stage committed failed: the inbox of the source %s did not move to the target %s: %s.  Retry or skip moves it again; the handover finishes only after the move"
              source target (error-message-string err)))
     nil)))

(defun claude-code-ide-handover--continue-request-id (run)
  "Return the request ID of the continue prompt of RUN."
  (concat "handover-continue:" (claude-code-ide-handover--run-id run)))

(defun claude-code-ide-handover--send-continue (run)
  "Send the target of RUN the continue prompt, when RUN asks for it.
Return nil when nothing more is needed: RUN asks for no prompt, its
record says that the inbox took it already (`continue-sent'), or the
inbox takes it now, also as a duplicate of the same request; then the
record is saved with `continue-sent' at once.  Return `busy' when that
save waits for the registry (the step runs again soon).  Else return
a text that says why it failed: an error of the submit, or a refusal
of the inbox.  The prompt goes through the inbox of the target
with a fixed request ID, so a second call (for example at a recovery)
sends nothing.  It waits in the inbox until the target is idle."
  (when (and (claude-code-ide-handover--run-continue run)
             (not (claude-code-ide-handover--run-continue-sent run)))
    (let ((result (condition-case err
                      (claude-code-ide-control-submit
                       (claude-code-ide-handover--run-target-id run)
                       claude-code-ide-handover--continue-prompt
                       :request-id (claude-code-ide-handover--continue-request-id run)
                       :queue t)
                    (error (list :error (error-message-string err))))))
      (if (memq (plist-get result :result) '(queued delivered unacknowledged))
          (progn
            ;; Saved at once, before the final save of the commit, so
            ;; that a recovery after a crash in between sends nothing
            ;; again, also after the inbox pruned its done record
            (setf (claude-code-ide-handover--run-continue-sent run) t)
            (if (claude-code-ide-handover--save run)
                nil
              (claude-code-ide-handover--busy-registry run)
              'busy))
        (or (plist-get result :error)
            (format "the inbox gave %s%s"
                    (or (plist-get result :result) (plist-get result :status) "no result")
                    (if (plist-get result :reason)
                        (format " (%s)" (plist-get result :reason))
                      "")))))))

(defun claude-code-ide-handover--run-of-target (instance-id)
  "Return the unfinished run of this Emacs whose target is INSTANCE-ID, or nil."
  (cl-find-if (lambda (run)
                (and (claude-code-ide-handover--unfinished-p run)
                     (equal (claude-code-ide-handover--run-target-id run) instance-id)))
              (hash-table-values claude-code-ide-handover--runs)))

(defun claude-code-ide-handover--on-event (event)
  "Follow the target of a handover, and the requests of agents, with EVENT.
A `session-start' of a target gives its native ID.  A `prompt-submit'
of a target whose prompt starts with the marker of its handover is the
delivery.  A `turn-end' of an instance with a handover request asks
the user."
  (let ((instance-id (plist-get event :instance-id))
        (data (plist-get event :data)))
    (pcase (plist-get event :event)
      ('session-start
       (when-let* ((run (claude-code-ide-handover--run-of-target instance-id))
                   (native (claude-code-ide-handover--event-value data "session_id"))
                   ((stringp native)))
         (claude-code-ide-handover--guarded run #'claude-code-ide-handover--identified run native)))
      ('prompt-submit
       (when-let* ((run (claude-code-ide-handover--run-of-target instance-id))
                   (prompt (claude-code-ide-handover--event-value data "prompt"))
                   ((equal (claude-code-ide-transcript-document-id prompt)
                           (claude-code-ide-handover--run-id run))))
         ;; After the other event functions, which set the native ID
         (run-at-time 0 nil #'claude-code-ide-handover--guarded
                      run #'claude-code-ide-handover--delivered run)))
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
  "Resume the identified target of RUN, and deliver the document when it lacks it.
This runs after a clean worktree scan.  A target that never saved its
conversation starts fresh instead; see
`claude-code-ide-handover--start-fresh-p'.  A target that lacks the
document gets the pointer prompt as the first prompt of its resume.  A
target that already runs gets it through the inbox."
  (if (claude-code-ide-handover--start-fresh-p run)
      (claude-code-ide-handover--start-fresh-target run)
    (claude-code-ide-handover--resume-saved-target run)))

(defun claude-code-ide-handover--resume-saved-target (run)
  "Resume the identified target of RUN.
See `claude-code-ide-handover--resume-target'."
  (let* ((id (claude-code-ide-handover--run-target-id run))
         (entry (claude-code-ide-session-registry-entry-of id))
         (delivered (or (not (claude-code-ide-handover--stage<
                              (claude-code-ide-handover--run-stage run) 'delivered))
                        (claude-code-ide-handover--target-delivered-p run)))
         (prompt (unless delivered (claude-code-ide-handover-start-prompt run)))
         (claude-code-ide-handover--allowed (claude-code-ide-handover--run-id run))
         (claude-code-ide-session-registry--handover-start id))
    (if (claude-code-ide-handover--live-target run)
        (when prompt
          (claude-code-ide-control-submit
           id prompt
           :request-id (or (claude-code-ide-handover--run-request-id run)
                           (concat "handover-" (claude-code-ide-handover--run-id run)))
           :queue t))
      (unless entry (error "The registry has no entry of the target %s" id))
      (unless (claude-code-ide-session-registry-entry-session-id entry)
        (setf (claude-code-ide-session-registry-entry-session-id entry)
              (claude-code-ide-handover--run-target-native-id run)))
      (claude-code-ide-session-registry--start-entry
       entry prompt (claude-code-ide-handover--run-interactive run)))
    (cond
     ((not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run) 'delivered))
      (claude-code-ide-handover--commit run))
     (delivered (claude-code-ide-handover--delivered run))
     (t (claude-code-ide-handover--start-watch run)))))

(defun claude-code-ide-handover--target-survivor (run)
  "Return the target CLI of RUN as a stray when it outlived its Emacs, or nil.
The registry entry of the target gives its process ID and start time."
  (when-let* (((not (claude-code-ide-handover--live-target run)))
              (entry (claude-code-ide-session-registry-entry-of
                      (claude-code-ide-handover--run-target-id run)))
              ((claude-code-ide-session-registry--owner-live-p entry)))
    (list :pid (claude-code-ide-session-registry-entry-pid entry)
          :command "the target CLI, still running"
          :cwd (claude-code-ide-handover--run-directory run)
          :reason 'target
          :start (claude-code-ide-session-registry-entry-process-start-time entry))))

(defun claude-code-ide-handover--target-native (run)
  "Return the native ID of the target of RUN: its own, else that of its entry."
  (or (claude-code-ide-handover--run-target-native-id run)
      (when-let* ((entry (claude-code-ide-session-registry-entry-of
                          (claude-code-ide-handover--run-target-id run))))
        (claude-code-ide-session-registry-entry-session-id entry))))

(defun claude-code-ide-handover--unsaved-target-p (run)
  "Return non-nil when the identified target of RUN never saved its conversation.
That is a target that does not run, has a native ID, and has no
transcript file for it: the provider finds none (for Claude Code the
session file of its registry entry, for Codex its rollout file).  A
resume of such a target fails, so the recovery starts it fresh; see
`claude-code-ide-handover-unsaved-target'."
  (let ((native (claude-code-ide-handover--target-native run)))
    (and (stringp native)
         (not (claude-code-ide-handover--live-target run))
         (not (claude-code-ide-handover--transcript-file
               (claude-code-ide-handover--run-target-provider run)
               native
               (claude-code-ide-session-registry-entry-of
                (claude-code-ide-handover--run-target-id run)))))))

(defun claude-code-ide-handover--start-fresh-p (run)
  "Return non-nil when the recovery starts the target of RUN fresh.
That is a target before the stage delivered that never saved its
conversation, while `claude-code-ide-handover-unsaved-target' is
`fresh'.  The check runs after the clean worktree scan, just before the
start: a target CLI that survived the crash can save its transcript
while the recovery waits for the strays, and then it is resumed."
  (and (eq claude-code-ide-handover-unsaved-target 'fresh)
       (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run) 'delivered)
       (claude-code-ide-handover--unsaved-target-p run)))

(defun claude-code-ide-handover--start-fresh-target (run)
  "Start the unsaved target of RUN fresh, with the same instance ID and document.
A Claude Code target keeps its native ID, which the start names with
--session-id (see `claude-code-ide-handover--fresh-session-flags').  A
fork, and a target of another provider, get the new ID of the CLI.  The
caller ran the worktree scan just before, so the start comes at once."
  (setf (claude-code-ide-handover--run-target-native-id run)
        (and (eq (claude-code-ide-handover--run-target-provider run) 'claude)
             (not (claude-code-ide-handover--run-fork-id run))
             (claude-code-ide-handover--target-native run))
        (claude-code-ide-handover--run-stage run) 'target-started)
  (claude-code-ide-handover--start-target run))

(defun claude-code-ide-handover--restart-target (run)
  "Start the target of RUN again after a crash, when no writer is left.
The worktree scan runs first, and a target CLI that outlived the crash
counts as a stray."
  (setf (claude-code-ide-handover--run-stage run) 'target-started)
  (claude-code-ide-handover--scan-then run 'start-target))

(defun claude-code-ide-handover--recover-run (run interactive)
  "Continue the interrupted RUN of an Emacs that ended.  Return its result.
This Emacs claims RUN first; when another live Emacs owns it, nothing
happens and the result is nil.  INTERACTIVE non-nil lets Emacs ask the
person about stray processes."
  (when (claude-code-ide-handover--claim run)
    (claude-code-ide-handover--recover-claimed run interactive)))

(defun claude-code-ide-handover--recover-claimed (run interactive)
  "Continue RUN, which this Emacs claimed; INTERACTIVE as for the recovery."
  (claude-code-ide-handover--sync-chain-saved run)
  (progn
    (puthash (claude-code-ide-handover--run-id run) run claude-code-ide-handover--runs)
    (setf (claude-code-ide-handover--run-status run) 'running
          (claude-code-ide-handover--run-interactive run) interactive)
    (let ((stage (claude-code-ide-handover--run-stage run)))
      ;; The source stopped: hold its inbox again, as the quiescing
      ;; did, so that a prompt for it waits for the move at the commit
      (unless (claude-code-ide-handover--stage< stage 'source-stopped)
        (claude-code-ide-control-hold (claude-code-ide-handover--run-source-id run)))
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
           ;; Never both: the source is not started again.  The scan
           ;; comes first; after it, `--resume-target' resumes the
           ;; target, or starts it fresh when it never saved its
           ;; conversation
           ((claude-code-ide-handover--target-native run)
            (claude-code-ide-handover--scan-then run 'resume-target))
           (t (claude-code-ide-handover--restart-target run)))
        (error
         (claude-code-ide-handover--needs-user
          run 'step-failed (format "Recovery at %s failed: %s" stage (error-message-string err)))))
      (claude-code-ide-handover--result run))))

(defun claude-code-ide-handover--interrupted-runs ()
  "Return the unfinished runs in the registry that no live Emacs runs.
The owner of a run is the Emacs in its own record (process ID and
start time), not the owner of the source entry."
  (cl-remove-if
   (lambda (run)
     (or (gethash (claude-code-ide-handover--run-id run) claude-code-ide-handover--runs)
         (eq (claude-code-ide-handover--run-owner run) 'other)))
   (cl-remove-if-not #'claude-code-ide-handover--unfinished-p
                     (claude-code-ide-handover--registry-runs))))

;;;###autoload
(defun claude-code-ide-handover-recover (&optional early-only interactive)
  "Continue the handovers that an ended Emacs left unfinished.
A handover before the stage source-stopped is cancelled: its source
stays current.  A later one never starts its source again: its target
is resumed when its native ID is known, else started again with the
same document.  A target whose native ID is known but whose
conversation was never saved cannot be resumed; see
`claude-code-ide-handover-unsaved-target'.  Each run is claimed in the
registry first, so that two
Emacs never recover the same handover.  With EARLY-ONLY, only cancel
the early ones.  INTERACTIVE non-nil (always for the command) lets
Emacs ask about stray processes.  Return the results."
  (interactive (list nil t))
  (let ((results nil) (late 0))
    (dolist (run (claude-code-ide-handover--interrupted-runs))
      (if (and early-only
               (not (claude-code-ide-handover--stage< (claude-code-ide-handover--run-stage run)
                                                      'source-stopped)))
          (setq late (1+ late))
        (when-let* ((result (claude-code-ide-handover--recover-run run interactive)))
          (push result results))))
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

(defun claude-code-ide-handover--read-method (target)
  "Ask whether the TARGET provider forks its last conversation of the chain.
Return `fork' or `fresh'.  Emacs asks only when a fork is possible.
`fork' is the default: RET or f.  n is a new conversation.  Any other
key is refused, and the question asks again."
  (let* ((provider (claude-code-ide-get-provider target))
         (name (or (and provider
                        (not (string-empty-p (claude-code-ide-provider-display-name provider)))
                        (claude-code-ide-provider-display-name provider))
                   (symbol-name target))))
    (pcase (car (read-multiple-choice
                 (format (concat "How should %s start?\n"
                                 "  fork: go on from the last %s conversation of this chain, "
                                 "with its full history, plus the handover document\n"
                                 "  new:  a new %s conversation that knows only the handover document\n"
                                 "Method")
                         name name name)
                 `((?f "fork" ,(format "go on from the last %s conversation, with its full history" name))
                   (?n "new" "a new conversation with only the handover document")
                   (?\r "fork" "the default: fork"))))
      (?n 'fresh)
      (_ 'fork))))

(defun claude-code-ide-handover--read-continue ()
  "Return `yes' or `no': whether the target goes on after the commit.
See `claude-code-ide-handover-continue'.  With `ask', ask once: y and
n hold for this handover; a and v also save `always' or `never' with
`customize-save-variable'.  When the save fails, the value holds in
this Emacs."
  (pcase claude-code-ide-handover-continue
    ('always 'yes)
    ('never 'no)
    (_
     (let* ((answer (car (read-multiple-choice
                          "After the handover, should the target go on with the task? "
                          '((?y "yes" "go on, this time")
                            (?n "no" "wait for my prompt, this time")
                            (?a "always" "always go on; save this")
                            (?v "never" "never go on; save this")))))
            (save (pcase answer (?a 'always) (?v 'never))))
       (when save
         (condition-case err
             (customize-save-variable 'claude-code-ide-handover-continue save)
           (error
            (setq claude-code-ide-handover-continue save)
            (message "claude-code-ide-handover-continue is %s in this Emacs; the save failed: %s"
                     save (error-message-string err)))))
       (if (memq answer '(?y ?a)) 'yes 'no)))))

(defun claude-code-ide-handover--check-worktree (key)
  "Signal a `user-error' when no handover can start in the working tree KEY.
A handover holds KEY, or an instance of another Emacs runs there."
  (when-let* ((run (claude-code-ide-handover--holding-run key)))
    (user-error "%s" (claude-code-ide-handover--held-message run)))
  (when-let* ((far (claude-code-ide-handover--other-emacs-entries key nil)))
    (user-error "%s" (claude-code-ide-handover--other-emacs-message key far))))

(defun claude-code-ide-handover--confirm-others (instance &optional exclude)
  "Ask whether to hand over INSTANCE while other sessions run in its working tree.
They are its other writers (`claude-code-ide-handover--writers').
Return their IDs, which the person confirmed (nil when there is none),
or signal `user-error' after n.  EXCLUDE is a list of IDs that the
question leaves out: the sources of a batch, whose targets also run
there.  With a prefix argument, the question does not come, and the
IDs are confirmed."
  (let* ((key (claude-code-ide-handover--instance-key instance))
         (ids (claude-code-ide-handover--writers
               key (append (claude-code-ide-handover--own-ids instance) exclude))))
    (cond
     ((or (null ids) current-prefix-arg) ids)
     ((y-or-n-p
       (format (concat "%d other %s in the worktree %s:\n%s\n"
                       "They go on with their work. The handover does not stop them or their processes.\n"
                       "The target gets this list.\n%sHand over anyway? ")
               (length ids) (if (cdr ids) "sessions run" "session runs") key
               (mapconcat (lambda (line) (concat "  " line))
                          (claude-code-ide-handover--writer-lines ids) "\n")
               (if exclude "The targets of the batch also run here.\n" "")))
      ids)
     (t (user-error "Handover not started")))))

(defun claude-code-ide-handover--read-target (source-provider)
  "Read the target provider; the default is a provider other than SOURCE-PROVIDER."
  (let ((default (symbol-name (or (car (remq source-provider (claude-code-ide-provider-names)))
                                  source-provider))))
    (intern (completing-read (format "Target provider (default %s): " default)
                             (mapcar #'symbol-name (claude-code-ide-provider-names))
                             nil t nil nil default))))

(defun claude-code-ide-handover--instance-fork-id (instance target)
  "Return the native ID that a handover of INSTANCE to TARGET forks, or nil."
  (claude-code-ide-handover--fork-id
   (claude-code-ide-handover--chain-of (claude-code-ide-instance-id instance))
   (list :provider (claude-code-ide-instance-provider instance)
         :native-id (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance)))
   target))

(defun claude-code-ide-handover--read-context-note (prompt)
  "Read a context note for a target with PROMPT; return nil for an empty answer."
  (let ((text (read-string prompt)))
    (unless (string-empty-p (string-trim text)) text)))

(defun claude-code-ide-handover--interruptible-p (state)
  "Return non-nil when a source in STATE is busy, so that an interrupt can help."
  (and (memq (plist-get state :state) '(working waiting-for-user))
       (not (claude-code-ide-handover--quiet-state-p state))))

(defun claude-code-ide-handover--read-args (&optional instance-id)
  "Read the arguments of `claude-code-ide-handover'.
INSTANCE-ID, when given, is the source; else it is the instance of the
current buffer, or one that you choose.  The checks of the working
tree and the question about other sessions come first; with a prefix
argument, that question does not come."
  (let* ((instance (or (and instance-id (claude-code-ide-instance-by-id instance-id))
                       (claude-code-ide-handover--current-instance)
                       (let* ((instances (cl-remove-if-not #'claude-code-ide-instance-live-p
                                                           (claude-code-ide-instances)))
                              (candidates (mapcar (lambda (i)
                                                    (cons (claude-code-ide-handover--instance-label i) i))
                                                  instances)))
                         (unless candidates (user-error "No instance runs"))
                         (cdr (assoc (completing-read "Hand over: " candidates nil t) candidates)))))
         (allow-others (progn
                         (claude-code-ide-handover--check-worktree
                          (claude-code-ide-handover--instance-key instance))
                         (claude-code-ide-handover--confirm-others instance)))
         (target (claude-code-ide-handover--read-target (claude-code-ide-instance-provider instance)))
         (method (if (claude-code-ide-handover--instance-fork-id instance target)
                     (claude-code-ide-handover--read-method target)
                   'fresh))
         (context (claude-code-ide-handover--read-context-note "Context for the target (empty for none): "))
         (state (claude-code-ide-instance-state instance))
         (interrupt (and (claude-code-ide-handover--interruptible-p state)
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
    (list (claude-code-ide-instance-id instance) target method context interrupt force
          ;; The last question: whether the target goes on after the commit
          (claude-code-ide-handover--read-continue)
          allow-others)))

(defun claude-code-ide-handover--continue-key (continue)
  "Return the :continue key of a handover for CONTINUE, `yes', `no' or nil."
  (pcase continue
    ('yes (list :continue t))
    ('no (list :continue nil))))

;;;###autoload
(defun claude-code-ide-handover (instance-id target-provider &optional method context interrupt force
                                             continue allow-others)
  "Hand the work of INSTANCE-ID to a new conversation of TARGET-PROVIDER.
METHOD is `fresh' or `fork', CONTEXT optional text for the target,
INTERRUPT non-nil to interrupt a busy source, and FORCE non-nil to go
on while its subagents or background tasks run, or while its state is
unknown.  CONTINUE is `yes' or `no': whether the target goes on with
the task after the commit; nil leaves it to
`claude-code-ide-handover-continue', where `ask' counts as `always'.
ALLOW-OTHERS is t or the list of the IDs of the other sessions of this
Emacs in the working tree that may run during the handover.
Interactively, the source is the instance of the current buffer, else
one that you choose, and Emacs asks for the rest, also CONTINUE when
the option is `ask', and whether to go on next to other sessions (a
prefix argument skips that question).  Emacs asks you about stray
processes after the stop.  See `claude-code-ide-handover-session'."
  (interactive (claude-code-ide-handover--read-args))
  (let ((result (apply #'claude-code-ide-handover-session
                       instance-id target-provider :method (or method 'fresh) :context context
                       :interrupt interrupt :force force :allow-others allow-others :interactive t
                       (claude-code-ide-handover--continue-key continue))))
    (if (eq (plist-get result :status) 'error)
        (user-error "Handover refused: %s%s" (plist-get result :reason)
                    (if (plist-get result :message) (concat ": " (plist-get result :message)) ""))
      (message "Handover %s started: %s -> %s" (plist-get result :handover-id)
               instance-id target-provider))
    result))

;;; Handovers of all instances of a working tree

(cl-defstruct (claude-code-ide-handover--batch
               (:constructor claude-code-ide-handover--batch-create)
               (:copier nil))
  "Handovers of the instances of one working tree, one after the other.
It lives in this Emacs only: a crash ends it."
  (key nil :documentation "The working tree.")
  (target-provider nil)
  (method 'fresh :documentation "`fork' or `fresh'; `fork' only for a source that can fork.")
  (contexts nil :documentation "Alist of source ID and context text.")
  (interrupt nil)
  (continue nil :documentation "`yes', `no' or nil, as for `claude-code-ide-handover'.")
  (confirmed nil :documentation "IDs of the sessions outside the batch that the person confirmed.")
  (all nil :documentation "IDs of all sources, in order.")
  (sources nil :documentation "IDs of the sources that are not started yet, in order.")
  (labels nil :documentation "Alist of source ID and its label, from the start of the batch.")
  (current nil :documentation "ID of the current handover, or nil.")
  (current-source nil :documentation "Source ID of the current handover, or nil.")
  (done nil :documentation "(SOURCE-ID . TARGET-ID) of each commit, newest first.")
  (skipped nil :documentation "(SOURCE-ID . REASON) of each skipped source, newest first.")
  (stopped-at nil :documentation "(SOURCE-ID . REASON) of the source where the batch stopped.")
  (retry nil :documentation "IDs of the sources refused with `hooks-not-trusted', for one more try.")
  (retried nil :documentation "IDs of the sources of the retry, once it began.")
  (stop nil :documentation "Non-nil: start no new handover.")
  (dead nil :documentation "Non-nil after the batch ended or was dropped.")
  (told nil :documentation "Non-nil after the wait message of the current handover.")
  (timer nil :documentation "The pending timer of the next step, or nil.")
  (result nil :documentation "The result of the first handover."))

;; shortcut: the batches live in memory and a crash ends them (the
;; current handover recovers), upgrade when a batch must outlive Emacs
(defvar claude-code-ide-handover--batches (make-hash-table :test 'equal)
  "The handover batches of this Emacs, by working tree.")

(defun claude-code-ide-handover--batch-label (batch id)
  "Return the label of the source ID of BATCH."
  (or (cdr (assoc id (claude-code-ide-handover--batch-labels batch))) id))

(defun claude-code-ide-handover--batch-stale-p (batch)
  "Return non-nil when BATCH has no unfinished current handover of this Emacs.
Its current handover is gone, final, or owned by another Emacs, whose
claim its registry record shows."
  (let* ((id (claude-code-ide-handover--batch-current batch))
         (run (claude-code-ide-handover--find id))
         (record (and run (cl-find id (claude-code-ide-handover--registry-runs)
                                   :key #'claude-code-ide-handover--run-id :test #'equal))))
    (not (and run
              (claude-code-ide-handover--unfinished-p run)
              (not (eq (and record (claude-code-ide-handover--run-owner record)) 'other))))))

(defun claude-code-ide-handover--batch-drop (batch)
  "Mark BATCH dead, cancel its pending timer, and take it out of the table.
It leaves the table only while the table maps its working tree to it,
so that an old batch never removes a new one."
  (setf (claude-code-ide-handover--batch-dead batch) t)
  (when (timerp (claude-code-ide-handover--batch-timer batch))
    (cancel-timer (claude-code-ide-handover--batch-timer batch)))
  (setf (claude-code-ide-handover--batch-timer batch) nil)
  (let ((key (claude-code-ide-handover--batch-key batch)))
    (when (eq (gethash key claude-code-ide-handover--batches) batch)
      (remhash key claude-code-ide-handover--batches))))

(defun claude-code-ide-handover--check-no-batch (key)
  "Signal a `user-error' when a batch of this Emacs runs in the working tree KEY.
A stale batch (`claude-code-ide-handover--batch-stale-p') is dropped
first, with a message, through `claude-code-ide-handover--batch-close'."
  (when-let* ((batch (gethash key claude-code-ide-handover--batches)))
    (if (claude-code-ide-handover--batch-stale-p batch)
        (progn
          (message "Handover batch in %s dropped at %s: its handover %s ended or is gone" key
                   (claude-code-ide-handover--batch-label
                    batch (claude-code-ide-handover--batch-current-source batch))
                   (claude-code-ide-handover--batch-current batch))
          (claude-code-ide-handover--batch-close batch))
      (user-error "A handover batch runs in %s; M-x claude-code-ide-handover-worktree-stop stops it"
                  key))))

(defun claude-code-ide-handover--batch-end (batch)
  "End BATCH, and tell the user what it handed over, skipped and did not start."
  (claude-code-ide-handover--batch-drop batch)
  (let* ((label (lambda (id) (claude-code-ide-handover--batch-label batch id)))
         (with-reason (lambda (item) (format "%s (%s)" (funcall label (car item)) (cdr item))))
         (or-none (lambda (items) (if items (string-join items ", ") "none")))
         ;; A source that waits for the retry when the batch ends was
         ;; refused with that reason
         (skipped (append (reverse (claude-code-ide-handover--batch-skipped batch))
                          (mapcar (lambda (id) (cons id 'hooks-not-trusted))
                                  (claude-code-ide-handover--batch-retry batch))))
         (stopped-at (claude-code-ide-handover--batch-stopped-at batch))
         (rest (claude-code-ide-handover--batch-sources batch)))
    (message "Handover batch in %s ended.  Handed over: %s.  Skipped: %s.  Stopped at, and not started: %s.%s"
             (claude-code-ide-handover--batch-key batch)
             (funcall or-none (mapcar (lambda (done)
                                        (format "%s -> %s%s" (funcall label (car done)) (cdr done)
                                                (if (member (car done) (claude-code-ide-handover--batch-retried batch))
                                                    " (in the retry)"
                                                  "")))
                                      (reverse (claude-code-ide-handover--batch-done batch))))
             (funcall or-none (mapcar with-reason skipped))
             (if stopped-at
                 (string-join (cons (funcall with-reason stopped-at)
                                    (and rest (list (string-join (mapcar label rest) ", "))))
                              "; ")
               (funcall or-none (mapcar label rest)))
             (if (or skipped stopped-at rest)
                 "  M-x claude-code-ide-handover-worktree hands over the rest."
               ""))))

(defun claude-code-ide-handover--batch-close (batch)
  "End BATCH now, without a new start.
A current handover whose end the status functions got is recorded
first, through `claude-code-ide-handover--batch-step'.  Else its source
is where BATCH stopped; an unfinished handover stays for
`claude-code-ide-handover-resolve'."
  (setf (claude-code-ide-handover--batch-stop batch) t)
  (let* ((id (claude-code-ide-handover--batch-current batch))
         (run (claude-code-ide-handover--find id)))
    (when (and run (not (claude-code-ide-handover--unfinished-p run)))
      (claude-code-ide-handover--batch-step batch id))
    (unless (claude-code-ide-handover--batch-dead batch)
      (when-let* ((source (claude-code-ide-handover--batch-current-source batch)))
        (setf (claude-code-ide-handover--batch-stopped-at batch)
              (cons source (format "handover %s %s" id
                                   (if run (claude-code-ide-handover--run-status run) "gone")))))
      (claude-code-ide-handover--batch-end batch))))

(defun claude-code-ide-handover--batch-next (batch)
  "Start the handover of the next source of BATCH, or end BATCH.
The handover may go on next to the confirmed sessions, the sources and
the targets of BATCH; another writer refuses it (`other-instance').  A
source that the handover refuses with `busy' or `not-running' is
skipped.  One refused with `hooks-not-trusted' waits for the retry:
when no other source is left, the batch tries each such source one
more time, in order, as before (the background trust check may have an
answer then); a second refusal skips it.  The batch stops at a stop
request, at another refusal, and at an error of the start."
  (setf (claude-code-ide-handover--batch-current batch) nil
        (claude-code-ide-handover--batch-current-source batch) nil)
  (let ((source (car (claude-code-ide-handover--batch-sources batch))))
    (cond
     ((claude-code-ide-handover--batch-stop batch)
      (claude-code-ide-handover--batch-end batch))
     ((and (null source) (claude-code-ide-handover--batch-retry batch))
      (setf (claude-code-ide-handover--batch-retried batch) (claude-code-ide-handover--batch-retry batch)
            (claude-code-ide-handover--batch-sources batch) (claude-code-ide-handover--batch-retry batch)
            (claude-code-ide-handover--batch-retry batch) nil)
      (claude-code-ide-handover--batch-next batch))
     ((null source)
      (claude-code-ide-handover--batch-end batch))
     (t
      (pop (claude-code-ide-handover--batch-sources batch))
      (let* ((instance (claude-code-ide-instance-by-id source))
             (target-provider (claude-code-ide-handover--batch-target-provider batch))
             (result
              (condition-case err
                  (apply #'claude-code-ide-handover-session source target-provider
                         :method (if (and instance
                                          (eq (claude-code-ide-handover--batch-method batch) 'fork)
                                          (claude-code-ide-handover--instance-fork-id
                                           instance target-provider))
                                     'fork
                                   'fresh)
                         :context (cdr (assoc source (claude-code-ide-handover--batch-contexts batch)))
                         :interrupt (claude-code-ide-handover--batch-interrupt batch)
                         :allow-others (append (claude-code-ide-handover--batch-confirmed batch)
                                               (claude-code-ide-handover--batch-all batch)
                                               (mapcar #'cdr (claude-code-ide-handover--batch-done batch)))
                         :interactive nil
                         :batch-next (claude-code-ide-handover--batch-sources batch)
                         (claude-code-ide-handover--continue-key
                          (claude-code-ide-handover--batch-continue batch)))
                (error (claude-code-ide-handover--error 'error (error-message-string err) source))))
             (reason (plist-get result :reason)))
        (unless (claude-code-ide-handover--batch-result batch)
          (setf (claude-code-ide-handover--batch-result batch) result))
        (cond
         ((not (eq (plist-get result :status) 'error))
          (setf (claude-code-ide-handover--batch-current batch) (plist-get result :handover-id)
                (claude-code-ide-handover--batch-current-source batch) source
                (claude-code-ide-handover--batch-told batch) nil)
          (message "Handover batch in %s: %d of %d: %s -> %s (%s)"
                   (claude-code-ide-handover--batch-key batch)
                   (1+ (cl-position source (claude-code-ide-handover--batch-all batch) :test #'equal))
                   (length (claude-code-ide-handover--batch-all batch))
                   (claude-code-ide-handover--batch-label batch source) target-provider
                   (plist-get result :handover-id)))
         ((and (eq reason 'hooks-not-trusted)
               (not (claude-code-ide-handover--batch-retried batch)))
          (setf (claude-code-ide-handover--batch-retry batch)
                (append (claude-code-ide-handover--batch-retry batch) (list source)))
          (claude-code-ide-handover--batch-next batch))
         ;; Fail safe: such a source stays current, and the others do
         ;; not depend on it
         ((memq reason '(busy not-running hooks-not-trusted))
          (push (cons source reason) (claude-code-ide-handover--batch-skipped batch))
          (claude-code-ide-handover--batch-next batch))
         (t
          (setf (claude-code-ide-handover--batch-stopped-at batch)
                (cons source (if (plist-get result :message)
                                 (format "%s: %s" reason (plist-get result :message))
                               reason)))
          (claude-code-ide-handover--batch-end batch))))))))

(defun claude-code-ide-handover--batch-on-status (run)
  "Schedule the next step of the batch whose current handover is RUN.
All work of the batch runs in that timer, outside the stack of the
handover."
  (when-let* ((batch (gethash (claude-code-ide-handover--run-worktree run)
                              claude-code-ide-handover--batches))
              ((equal (claude-code-ide-handover--batch-current batch)
                      (claude-code-ide-handover--run-id run))))
    (setf (claude-code-ide-handover--batch-timer batch)
          (run-at-time 0 nil #'claude-code-ide-handover--batch-step
                       batch (claude-code-ide-handover--run-id run)))))

(add-hook 'claude-code-ide-handover--status-functions #'claude-code-ide-handover--batch-on-status)

(defun claude-code-ide-handover--batch-step (batch handover-id)
  "Go on with BATCH after its handover HANDOVER-ID ended or needs a person.
Nothing happens unless the table still maps the working tree to BATCH,
BATCH is not dead, and HANDOVER-ID is still its current handover: an
old timer never moves a newer batch, and a second call for the same
handover does nothing.  A committed or cancelled run counts only after
the status functions got its end (`ended': its final save succeeded);
a notification of needs-user only waits."
  (when-let* (((eq (gethash (claude-code-ide-handover--batch-key batch)
                            claude-code-ide-handover--batches)
                   batch))
              ((not (claude-code-ide-handover--batch-dead batch)))
              ((equal (claude-code-ide-handover--batch-current batch) handover-id))
              (run (claude-code-ide-handover--find handover-id)))
    (setf (claude-code-ide-handover--batch-timer batch) nil)
    (let ((source (claude-code-ide-handover--run-source-id run))
          (reason (claude-code-ide-handover--run-reason run))
          (ended (claude-code-ide-handover--run-ended run)))
      (pcase (claude-code-ide-handover--run-status run)
        ((and 'committed (guard ended))
         (push (cons source (claude-code-ide-handover--run-target-id run))
               (claude-code-ide-handover--batch-done batch))
         (claude-code-ide-handover--batch-next batch))
        ;; An automatic cancel before the stop: the source stays current
        ((and 'cancelled (guard ended) (guard (memq reason '(busy not-idle recovered-before-stop))))
         (push (cons source reason) (claude-code-ide-handover--batch-skipped batch))
         (claude-code-ide-handover--batch-next batch))
        ((and 'cancelled (guard ended))
         (setf (claude-code-ide-handover--batch-stopped-at batch) (cons source reason))
         (claude-code-ide-handover--batch-end batch))
        ('needs-user
         (unless (claude-code-ide-handover--batch-told batch)
           (setf (claude-code-ide-handover--batch-told batch) t)
           (message "Handover batch waits at %s: %s; M-x claude-code-ide-handover-resolve"
                    (claude-code-ide-handover--batch-label batch source) reason)))))))

(defun claude-code-ide-handover--read-worktree (prompt keys none)
  "Return the working tree of the instance of the current buffer, if in KEYS.
Else read one of KEYS with PROMPT; one key needs no question.  Without
KEYS, signal a `user-error' with the text NONE."
  (let ((own (when-let* ((instance (claude-code-ide-handover--current-instance)))
               (claude-code-ide-handover--instance-key instance))))
    (cond
     ((member own keys) own)
     ((null keys) (user-error "%s" none))
     ((cdr keys) (completing-read prompt keys nil t))
     (t (car keys)))))

(defun claude-code-ide-handover--read-batch-args ()
  "Read the arguments of `claude-code-ide-handover-worktree'.
The checks of the working tree come before any question, and each
question comes once, before the first handover: the target, the Codex
hook trust, the sources, the other sessions, the method, the interrupt
policy, a context note for each source, and continue."
  (let* ((live (cl-remove-if-not #'claude-code-ide-instance-live-p (claude-code-ide-instances)))
         (key (claude-code-ide-handover--read-worktree
               "Hand over the instances of the working tree: "
               (delete-dups (delq nil (mapcar #'claude-code-ide-handover--instance-key live)))
               "No instance runs")))
    (claude-code-ide-handover--check-no-batch key)
    (claude-code-ide-handover--check-worktree key)
    (let* ((here (cl-remove-if-not (lambda (instance)
                                     (equal (claude-code-ide-handover--instance-key instance) key))
                                   live))
           (current (car (memq (claude-code-ide-handover--current-instance) here)))
           (target (claude-code-ide-handover--read-target
                    (claude-code-ide-instance-provider (or current (car here)))))
           (candidates (progn
                         (when (and (eq target 'codex)
                                    (not (claude-code-ide-handover--codex-trusted-p key t)))
                           (user-error "%s" claude-code-ide-handover--untrusted-message))
                         (mapcar (lambda (instance)
                                   (cons (claude-code-ide-handover--instance-label instance) instance))
                                 (cl-remove target here :key #'claude-code-ide-instance-provider))))
           (chosen (if candidates
                       (completing-read-multiple "Hand over (empty for all): " candidates nil t)
                     (user-error "No instance in %s runs a provider other than %s" key target)))
           (sources (if chosen
                        (cl-remove-if-not (lambda (candidate) (member (car candidate) chosen)) candidates)
                      candidates))
           (instances (mapcar #'cdr sources))
           (ids (mapcar #'claude-code-ide-instance-id instances))
           (confirmed (claude-code-ide-handover--confirm-others (car instances) ids))
           (method (if (cl-some (lambda (instance)
                                  (claude-code-ide-handover--instance-fork-id instance target))
                                instances)
                       (claude-code-ide-handover--read-method target)
                     'fresh))
           (interrupt (and (cl-some (lambda (instance)
                                      (claude-code-ide-handover--interruptible-p
                                       (claude-code-ide-instance-state instance)))
                                    instances)
                           (y-or-n-p "Interrupt a busy session (else wait until it is idle)? ")))
           (contexts (delq nil (mapcar (lambda (source)
                                         (when-let* ((text (claude-code-ide-handover--read-context-note
                                                            (format "Context for %s (empty for none): "
                                                                    (car source)))))
                                           (cons (claude-code-ide-instance-id (cdr source)) text)))
                                       sources))))
      (list ids target method contexts interrupt (claude-code-ide-handover--read-continue) confirmed))))

;;;###autoload
(defun claude-code-ide-handover-worktree (instance-ids target-provider &optional method contexts
                                                       interrupt continue confirmed)
  "Hand over the instances INSTANCE-IDS of one working tree to TARGET-PROVIDER.
The handovers run one after the other: each starts after the previous
one ended.  METHOD is `fork' or `fresh'; with `fork', a source forks
when its chain has a conversation of TARGET-PROVIDER, else it starts
fresh.  CONTEXTS is an alist of instance ID and context text.
INTERRUPT non-nil interrupts a busy source one time.  CONTINUE is
`yes', `no' or nil, as for `claude-code-ide-handover'.  CONFIRMED is
the list of the IDs of the other sessions in the working tree that
you confirmed; a session that is not in it, and not of the batch,
refuses the next handover, and the batch stops.  Every live source
must be in the working tree of the first one.

After an automatic cancel (`busy', `not-idle'), and a refusal with
`busy', `not-running' or `hooks-not-trusted', the batch skips that
source; after a cancel of yours it stops; at `needs-user' it waits
for `claude-code-ide-handover-resolve'.  The batch never forces a
handover, and no handover of it asks a question.
\\[claude-code-ide-handover-worktree-stop] stops it.  Interactively,
Emacs asks each question once, before the first handover; a prefix
argument skips the question about other sessions.  Return the result
of the first handover."
  (interactive (claude-code-ide-handover--read-batch-args))
  (let* ((first (claude-code-ide-instance-by-id (car instance-ids)))
         (key (and first (claude-code-ide-handover--instance-key first))))
    (unless key (user-error "The instance %s does not run" (car instance-ids)))
    (when-let* ((outside (cl-remove-if
                          (lambda (id)
                            (let ((instance (claude-code-ide-instance-by-id id)))
                              (or (not (and instance (claude-code-ide-instance-live-p instance)))
                                  (equal (claude-code-ide-handover--instance-key instance) key))))
                          instance-ids)))
      (user-error "The sources %s do not run in the working tree %s" (string-join outside ", ") key))
    (claude-code-ide-handover--check-no-batch key)
    (let ((batch (claude-code-ide-handover--batch-create
                  :key key :target-provider target-provider :method (or method 'fresh)
                  :contexts contexts :interrupt interrupt :continue continue :confirmed confirmed
                  :all instance-ids :sources instance-ids
                  :labels (mapcar (lambda (id)
                                    (cons id (if-let* ((instance (claude-code-ide-instance-by-id id)))
                                                 (claude-code-ide-handover--instance-label instance)
                                               id)))
                                  instance-ids))))
      (puthash key batch claude-code-ide-handover--batches)
      (claude-code-ide-handover--batch-next batch)
      (claude-code-ide-handover--batch-result batch))))

(defun claude-code-ide-handover-worktree-stop (worktree)
  "Stop the handover batch in WORKTREE: it starts no new handover.
The current handover goes on to its end;
\\[claude-code-ide-handover-cancel] cancels it.  A batch whose current
handover ended, or waits for a person, ends at once (see
`claude-code-ide-handover--batch-close'); a handover that waits stays
for `claude-code-ide-handover-resolve'.  Interactively, WORKTREE is the
working tree of the current buffer, else one that you choose."
  (interactive (list (claude-code-ide-handover--read-worktree
                      "Stop the handover batch in: "
                      (hash-table-keys claude-code-ide-handover--batches)
                      "No handover batch runs")))
  (let ((batch (gethash worktree claude-code-ide-handover--batches)))
    (unless batch (user-error "No handover batch runs in %s" worktree))
    (setf (claude-code-ide-handover--batch-stop batch) t)
    (if (or (claude-code-ide-handover--batch-stale-p batch)
            (eq (claude-code-ide-handover--run-status
                 (claude-code-ide-handover--find (claude-code-ide-handover--batch-current batch)))
                'needs-user))
        (claude-code-ide-handover--batch-close batch)
      (message "Handover batch in %s stops after the handover %s; M-x claude-code-ide-handover-cancel cancels it"
               worktree (claude-code-ide-handover--batch-current batch)))))

;;; Requests of agents

(defun claude-code-ide-handover--offer-request (instance-id)
  "Ask the user about the handover request of INSTANCE-ID, after its turn end.
After a yes, the question about other sessions in the working tree
comes too (see `claude-code-ide-handover--confirm-others')."
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
                                (plist-get request :method) (plist-get request :context) nil nil nil
                                (claude-code-ide-handover--confirm-others instance)))))

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
    (claude-code-ide-control-json
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
  "Return non-nil when the MCP argument VALUE is true.
The MCP server decodes JSON false as `:json-false'; `:false' (the
default of `json-parse-string') and the texts false, no, 0 and the
empty text count as false too."
  (and value (not (memq value '(:json-false :false)))
       (not (member value '("false" "" "no" "0"))) t))

(defun claude-code-ide-handover--mcp-handover (instance-id target-provider &optional method context
                                                           interrupt force request-id continue
                                                           allow-others)
  "MCP tool: hand INSTANCE-ID over to TARGET-PROVIDER.
METHOD, CONTEXT, INTERRUPT, FORCE, REQUEST-ID, CONTINUE and
ALLOW-OTHERS are the tool arguments.  CONTINUE goes to the handover
only when the call gives it."
  (claude-code-ide-control-json
   (apply #'claude-code-ide-control-call
          'handover instance-id target-provider
          :method (if (and (stringp method) (string= method "fork")) 'fork 'fresh)
          :context (unless (claude-code-ide-control-blank-p context) context)
          :interrupt (claude-code-ide-handover--flag interrupt)
          :force (claude-code-ide-handover--flag force)
          :allow-others (claude-code-ide-handover--flag allow-others)
          :request-id (unless (claude-code-ide-control-blank-p request-id) request-id)
          (unless (null continue)
            (list :continue (claude-code-ide-handover--flag continue))))))

(defun claude-code-ide-handover--mcp-status (handover-id)
  "MCP tool: return the result of the handover HANDOVER-ID (or request ID)."
  (claude-code-ide-control-json (claude-code-ide-handover-status handover-id)))

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
                     :description "Hand over while subagents or background tasks run, or other instances run in the working tree.")
             '(:name "request_id" :type string :optional t
                     :description "ID that makes the request idempotent.")
             '(:name "continue" :type boolean :optional t
                     :description "After the commit, tell the target to go on with the task of its state summary (true), or let it wait for a prompt (false). Default: the user's option claude-code-ide-handover-continue; its value ask counts as true here.")
             '(:name "allow_others" :type boolean :optional t
                     :description "Hand over while other instances of this Emacs run in the working tree. Unlike force, it does not stop subagents or background tasks.")))

(claude-code-ide-control-define-tool
 :name "claude-code-ide-control-handover-status"
 :function #'claude-code-ide-handover--mcp-status
 :description "Return the status of a handover: running, needs-user, committed, cancelled or failed, with its stage, the target instance ID and the stray processes."
 :args '((:name "handover_id" :type string :description "Handover ID or request ID of the handover.")))

(provide 'claude-code-ide-handover)

;;; claude-code-ide-handover.el ends here
