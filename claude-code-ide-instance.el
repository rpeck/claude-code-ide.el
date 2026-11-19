;;; claude-code-ide-instance.el --- Instance descriptors, events and states  -*- lexical-binding: t; -*-

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

;; An instance is one terminal session of a coding-agent CLI that Emacs
;; runs.  Each instance has one `claude-code-ide-instance' descriptor.
;; Its instance ID comes from Emacs and does not change, also across a
;; resume or a restore.  The native conversation ID and the display name
;; are separate values.  A value that Emacs does not know is the symbol
;; `unknown', never a guess.
;;
;; The launch generation of an instance increases at each launch, resume
;; and restore.  A common event carries the instance ID and the
;; generation of the launch that sent it, so an event of an earlier
;; launch is recognized and ignored.
;;
;; `claude-code-ide-instance-state' gives the state of an instance in the
;; common states of all providers.  docs/session-schema.md describes the
;; descriptor, the common event and the states.

;;; Code:

(require 'cl-lib)

;;; Unknown values

(defun claude-code-ide-unknown-p (value)
  "Return non-nil when VALUE is the explicit unknown value."
  (eq value 'unknown))

(defun claude-code-ide-or-unknown (value)
  "Return VALUE, or `unknown' when VALUE is nil."
  (if (null value) 'unknown value))

(defun claude-code-ide-known-or-nil (value)
  "Return VALUE, or nil when VALUE is `unknown'."
  (unless (claude-code-ide-unknown-p value) value))

(defun claude-code-ide-format-value (value)
  "Return VALUE as text for people: \"unknown\" for an unknown value.
nil gives the empty string; a symbol gives its name."
  (cond
   ((null value) "")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

;;; Descriptor

(cl-defstruct (claude-code-ide-instance
               (:constructor claude-code-ide-instance-create)
               (:copier nil))
  "Descriptor of one instance: one terminal session that Emacs runs.
Control operations find an instance by its ID only.  Display names are
for people, and two instances can have the same one."
  (id nil :type string :documentation "Instance ID.  It comes from Emacs and does not change.")
  (provider nil :type symbol :documentation "Name of the provider, such as `claude'.")
  (native-id 'unknown :documentation "Native conversation ID, or `unknown'.")
  (display-name 'unknown :documentation "Name that people see, or `unknown'.")
  (project-root 'unknown :documentation "Directory that the instance runs in.")
  (worktree 'unknown :documentation "Top directory of the Git working tree, or `unknown'.")
  (buffer nil :documentation "Terminal buffer, or nil before it exists.")
  (pid 'unknown :documentation "Process ID of the terminal process, or `unknown'.")
  (process-start-time 'unknown
                      :documentation "Start time of that process as a float, or `unknown'.")
  (generation 0 :type integer :documentation "Launch generation of the current launch.")
  (model 'unknown :documentation "Model of the conversation, or `unknown'.")
  (role nil :documentation "Optional role string that a coordinator gives, or nil.")
  (session nil :documentation "The `claude-code-ide-mcp-session' of the instance, or nil.")
  (properties nil :type list
              :documentation "Plist for values of other files; see
`claude-code-ide-instance-property'."))

(defvar claude-code-ide-instance--all nil
  "Descriptors of the instances that run in this Emacs, oldest first.")

(defvar claude-code-ide-instance--generations (make-hash-table :test 'equal)
  "Last launch generation of each instance ID.
An entry stays after its instance ends, so a later launch of the same
ID gets a higher generation.")

(defun claude-code-ide-instance-new-id ()
  "Return a new instance ID: a random UUID (version 4)."
  (let ((hex (secure-hash 'sha256 (format "%S %S %S %S" (current-time) (emacs-pid)
                                          (random) (random)))))
    (format "%s-%s-4%s-%x%s-%s"
            (substring hex 0 8)
            (substring hex 8 12)
            (substring hex 13 16)
            (logior 8 (logand 3 (string-to-number (substring hex 16 17) 16)))
            (substring hex 17 20)
            (substring hex 20 32))))

(defun claude-code-ide-instance-property (instance key)
  "Return the value of KEY in the properties of INSTANCE.
Files that are not part of the frozen descriptor keep their own values
here, under keys that start with their own name."
  (plist-get (claude-code-ide-instance-properties instance) key))

(defun claude-code-ide-instance-set-property (instance key value)
  "Set KEY to VALUE in the properties of INSTANCE and return VALUE."
  (setf (claude-code-ide-instance-properties instance)
        (plist-put (claude-code-ide-instance-properties instance) key value))
  value)

(defun claude-code-ide-instance-by-id (instance-id)
  "Return the descriptor of the running instance INSTANCE-ID, or nil."
  (cl-find instance-id claude-code-ide-instance--all
           :key #'claude-code-ide-instance-id :test #'equal))

(defun claude-code-ide-instance-of-session (session)
  "Return the descriptor whose MCP session is SESSION, or nil."
  (and session
       (cl-find session claude-code-ide-instance--all
                :key #'claude-code-ide-instance-session :test #'eq)))

(defun claude-code-ide-instances (&optional provider)
  "Return the descriptors of the running instances, oldest first.
With PROVIDER, a provider name, return only its instances."
  (if provider
      (cl-remove-if-not (lambda (instance)
                          (eq (claude-code-ide-instance-provider instance) provider))
                        claude-code-ide-instance--all)
    (copy-sequence claude-code-ide-instance--all)))

(defun claude-code-ide-instance-live-p (instance)
  "Return non-nil when the terminal of INSTANCE still runs.
That is: its buffer is live, and its process is live or not yet known."
  (let* ((session (claude-code-ide-instance-session instance))
         (buffer (claude-code-ide-instance-buffer instance))
         (process (and (buffer-live-p buffer) (get-buffer-process buffer))))
    (and (memq instance claude-code-ide-instance--all)
         (buffer-live-p buffer)
         (or (null process) (process-live-p process))
         (not (and session
                   (fboundp 'claude-code-ide-mcp-session-cleanup-done)
                   (funcall 'claude-code-ide-mcp-session-cleanup-done session))))))

(defun claude-code-ide-instance-register (instance)
  "Add INSTANCE to the running instances and return it.
Signal an error when a live instance has the same ID; then nothing
changes.  Else the generation of INSTANCE becomes the current
generation of its ID, so get it from
`claude-code-ide-instance-candidate-generation' first."
  (let* ((id (claude-code-ide-instance-id instance))
         (old (claude-code-ide-instance-by-id id)))
    (unless (stringp id)
      (error "An instance needs a string ID, not %S" id))
    (when old
      (if (claude-code-ide-instance-live-p old)
          (error "Instance %s already runs" id)
        (claude-code-ide-instance-unregister id)))
    (puthash id (max (claude-code-ide-instance-generation instance)
                     (gethash id claude-code-ide-instance--generations 0))
             claude-code-ide-instance--generations)
    (setq claude-code-ide-instance--all
          (append claude-code-ide-instance--all (list instance)))
    instance))

(defun claude-code-ide-instance-unregister (instance-id)
  "Remove the instance INSTANCE-ID from the running instances.
Its last generation stays known."
  (setq claude-code-ide-instance--all
        (cl-remove instance-id claude-code-ide-instance--all
                   :key #'claude-code-ide-instance-id :test #'equal)))

;;; Launch generations

(defun claude-code-ide-instance-current-generation (instance-id)
  "Return the generation of the last launch of INSTANCE-ID, or nil."
  (gethash instance-id claude-code-ide-instance--generations))

(defun claude-code-ide-instance-candidate-generation (instance-id &optional last)
  "Return the generation for a new launch of INSTANCE-ID, without recording it.
That is one more than the highest of LAST (the generation that a saved
record holds, or nil) and the last generation in this Emacs.
`claude-code-ide-instance-register' records it, so a launch that fails
before it changes nothing."
  (1+ (max (or last 0)
           (gethash instance-id claude-code-ide-instance--generations 0))))

(defun claude-code-ide-instance-next-generation (instance-id &optional last)
  "Return the generation for a new launch of INSTANCE-ID and record it.
See `claude-code-ide-instance-candidate-generation'.  A launch uses the
candidate and registers its descriptor instead, so that a refused
launch leaves the current generation alone."
  (let ((generation (claude-code-ide-instance-candidate-generation instance-id last)))
    (puthash instance-id generation claude-code-ide-instance--generations)
    generation))

;;; Common events

(defconst claude-code-ide-event-names
  '(session-start session-end prompt-submit tool-start tool-end
                  approval-request dialog-open dialog-close notification
                  turn-end turn-failed interrupt subagent-start subagent-end other)
  "Names of the common events, the value of :event in a common event.
A provider maps each of its own events to one of them; `other' is an
event without a common meaning.")

(defvar claude-code-ide-event-functions nil
  "Functions called with each current common event.
`claude-code-ide-dispatch-event' calls them; it drops the events of
earlier launches first.")

(defun claude-code-ide-make-event (instance-id generation event provider-event data
                                               &optional time)
  "Return a common event as a plist.
INSTANCE-ID and GENERATION identify the launch that sent it.  EVENT is
a symbol of `claude-code-ide-event-names'.  PROVIDER-EVENT is the name
of the event in the provider, and DATA its input.  TIME is a float
time; nil means now."
  (unless (memq event claude-code-ide-event-names)
    (error "Unknown common event: %S" event))
  (list :instance-id instance-id
        :generation generation
        :time (or time (float-time))
        :event event
        :provider-event provider-event
        :data data))

(defun claude-code-ide-event-current-p (event)
  "Return non-nil unless EVENT comes from an earlier launch of its instance.
An event of an instance ID that this Emacs never launched is not current."
  (let ((current (claude-code-ide-instance-current-generation
                  (plist-get event :instance-id)))
        (generation (plist-get event :generation)))
    (and current (integerp generation) (>= generation current))))

(defun claude-code-ide-dispatch-event (event)
  "Pass EVENT to `claude-code-ide-event-functions' when it is current.
Return non-nil when EVENT was passed on, nil when it was dropped."
  (when (claude-code-ide-event-current-p event)
    (run-hook-with-args 'claude-code-ide-event-functions event)
    t))

;;; States

(defconst claude-code-ide-instance-states
  '((working starting)
    (idle)
    (waiting-for-user approval question dialog)
    (waiting-for-task subagent background-task other-instance)
    (disconnected untracked no-signal)
    (failed quota-limit exit-code error))
  "The common states, each with the reasons it can have.")

(defvar claude-code-ide-instance-state-functions nil
  "Functions that give the state of a live instance.
Each function is called with INSTANCE and NOW (a float time) and
returns a state from `claude-code-ide-instance-make-state', or nil
when it does not know INSTANCE.  The first non-nil result is used.")

(defun claude-code-ide-instance-make-state (state &optional reason since guess)
  "Return a state plist for STATE with REASON, SINCE and GUESS.
STATE and REASON must be in `claude-code-ide-instance-states'.  SINCE
is the float time when the state started, or nil when it is not known.
GUESS non-nil marks a state that Emacs infers and that no event
reports."
  (let ((reasons (assq state claude-code-ide-instance-states)))
    (unless reasons
      (error "Unknown instance state: %S" state))
    (when (and reason (not (memq reason (cdr reasons))))
      (error "Unknown reason %S for the state %S" reason state))
    (list :state state :reason reason :since since :guess (and guess t))))

(defun claude-code-ide-instance-state (instance &optional now)
  "Return the state of INSTANCE at NOW as a plist.
INSTANCE is a descriptor or an instance ID; NOW is a float time and
defaults to now.  The plist has :state, :reason (nil for a state
without one), :since (the float time when the state started, or nil),
:age (seconds from :since to NOW, or nil) and :guess.  An instance whose
process is gone, or about which no state function knows anything, is
`disconnected'.  Return nil for an ID that this Emacs never launched."
  (let* ((now (or now (float-time)))
         (descriptor (if (claude-code-ide-instance-p instance)
                         instance
                       (claude-code-ide-instance-by-id instance)))
         (id (if (claude-code-ide-instance-p instance)
                 (claude-code-ide-instance-id instance)
               instance))
         (state
          (cond
           ((and descriptor (claude-code-ide-instance-live-p descriptor))
            (or (run-hook-with-args-until-success
                 'claude-code-ide-instance-state-functions descriptor now)
                (claude-code-ide-instance-make-state 'disconnected)))
           ((or descriptor (claude-code-ide-instance-current-generation id))
            (claude-code-ide-instance-make-state 'disconnected)))))
    (when state
      (let ((since (plist-get state :since)))
        (append state (list :age (and since (max 0 (- now since)))))))))

(provide 'claude-code-ide-instance)

;;; claude-code-ide-instance.el ends here
