;;; claude-code-ide-live-tests.el --- Live tests with the real Claude Code and Codex CLIs  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Live tests of the handover and of the Codex dialogs.  They start the
;; real `claude' and `codex' CLIs in real terminals, so they cost quota
;; and take minutes.  They run only in an Emacs daemon of their own,
;; with CLAUDE_CODE_IDE_LIVE_TESTS=1; in batch Emacs, and in the mocked
;; suite of claude-code-ide-tests.el, each test skips.
;;
;; docs/live-tests.md tells how to start the daemon, which variables
;; select the optional parts, and what each test writes outside its
;; folder (folder trust entries of the CLIs, transcripts).
;;
;; All state of the package goes to the live folder
;; (CLAUDE_CODE_IDE_LIVE_DIR, default tmp/live/ next to this file): the
;; registry, the report folder with the hooks, the inbox, the MCP
;; config files, the provider file and the IDE lock files.  The CLIs
;; keep their own login and configuration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-control)
(require 'claude-code-ide-codex)
(require 'claude-code-ide-codex-events)
(require 'claude-code-ide-handover)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-emacs-tools)

(defvar claude-code-ide-mcp-allowed-tools)
(defvar claude-code-ide-enable-mcp-server)
(defvar claude-code-ide-handover-session-server)

(declare-function claude-code-ide-mcp--lockfile-directory "claude-code-ide-mcp" ())
(declare-function vterm-send-down "vterm" ())

;;; The gate and the folders

(defconst claude-code-ide-live-tests--file
  (or load-file-name buffer-file-name)
  "This file.")

(defun claude-code-ide-live-tests--live-p ()
  "Return non-nil when the live tests may run in this Emacs.
They need CLAUDE_CODE_IDE_LIVE_TESTS=1, a daemon of their own that is
not in batch mode (the CLIs need real terminals, and a person's Emacs
must never run them), and the real packages, not the mocks of
claude-code-ide-tests.el.  A daemon of its own started without an init
file (emacs -Q: `init-file-user' is nil), or has a name that starts
with cci-live; a person's daemon loads an init file."
  (let ((daemon (daemonp)))
    (and (equal (getenv "CLAUDE_CODE_IDE_LIVE_TESTS") "1")
         (not noninteractive)
         daemon
         (or (null init-file-user)
             (and (stringp daemon) (string-prefix-p "cci-live" daemon)))
         (not (featurep 'claude-code-ide-tests)))))

(defmacro claude-code-ide-live-tests--skip-unless-live ()
  "Skip the current test unless the live tests may run."
  '(progn
     (skip-unless (claude-code-ide-live-tests--live-p))
     (claude-code-ide-live-tests-setup)))

(defmacro claude-code-ide-live-tests--live (&rest body)
  "Run BODY of a live test between two cleanups, or skip the test.
The test skips unless the live tests may run here
\(`claude-code-ide-live-tests--live-p'); else the setup runs.  Before
BODY, every instance of this Emacs stops.  After BODY, also after a
failure or a skip, every instance stops again and the codeword files
that the test made go.

When BODY starts with :keep-instances, nothing stops before BODY: the
test checks instances that this Emacs started before it, such as the
target that the recovery at the start of Emacs started."
  (declare (indent 0))
  (let ((keep (eq (car body) :keep-instances)))
    `(progn
       (claude-code-ide-live-tests--skip-unless-live)
       ,@(unless keep '((claude-code-ide-live-tests--stop-all)))
       (unwind-protect
           (progn ,@(if keep (cdr body) body))
         (claude-code-ide-live-tests--cleanup)))))

(defun claude-code-ide-live-tests--root ()
  "Return the live folder, with a final slash."
  (file-name-as-directory
   (expand-file-name
    (or (getenv "CLAUDE_CODE_IDE_LIVE_DIR")
        (expand-file-name "tmp/live/" (file-name-directory claude-code-ide-live-tests--file))))))

(defun claude-code-ide-live-tests--path (name)
  "Return the file NAME in the live folder."
  (expand-file-name name (claude-code-ide-live-tests--root)))

(defun claude-code-ide-live-tests--log (format-string &rest args)
  "Append a line made of FORMAT-STRING and ARGS to log.txt of the live folder.
Only a live run (`claude-code-ide-live-tests--live-p') writes the file;
elsewhere, for example in a unit test of a helper, the line goes only
to *Messages*."
  (let ((line (concat (format-time-string "%FT%T ") (apply #'format format-string args) "\n")))
    (when (claude-code-ide-live-tests--live-p)
      (write-region line nil (claude-code-ide-live-tests--path "log.txt") t 'silent))
    (message "%s" (string-trim-right line))))

;;; Setup

(defvar claude-code-ide-live-tests--setup-done nil
  "Non-nil after `claude-code-ide-live-tests-setup' ran in this Emacs.")

(defvar claude-code-ide-live-tests--assume-hook-trust t
  "Non-nil: the Codex status hooks count as trusted.
The hook script of the live folder has no trust record in the Codex
config, and the tests never write one.  So the tests pass
--dangerously-bypass-hook-trust to Codex and let the trust cache say
`trusted'.  nil gives the real check (the hooks-not-trusted test).")

(defvar claude-code-ide-live-tests--events nil
  "The common events of this Emacs, newest first, as (TIME . EVENT).")

(defvar claude-code-ide-live-tests--starts nil
  "The starts of this Emacs, newest first, as (INSTANCE-ID PROVIDER RESUME-ID).")

(defun claude-code-ide-live-tests--note-event (event)
  "Keep EVENT with the time it came."
  (push (cons (float-time) event) claude-code-ide-live-tests--events))

(defun claude-code-ide-live-tests--lockfile-directory ()
  "Return the folder of the IDE lock files of the live tests."
  (file-name-as-directory (claude-code-ide-live-tests--path "ide")))

(defun claude-code-ide-live-tests--cached-trust (function key)
  "Call FUNCTION with KEY, or return a trusted result.
See `claude-code-ide-live-tests--assume-hook-trust'."
  (if claude-code-ide-live-tests--assume-hook-trust
      (list :status 'trusted :message nil :trust nil :cache 'ttl :checked-at (float-time))
    (funcall function key)))

(defun claude-code-ide-live-tests--note-start (&rest args)
  "Keep the instance ID, the provider and the resume ID of a start.
ARGS are those of `claude-code-ide--start-session'; the spec is the
third one.  The record goes to starts.txt of the live folder too, so
that a test after a restart of Emacs sees the starts before it."
  (let ((spec (nth 2 args)))
    (when (claude-code-ide-start-spec-p spec)
      (let ((record (list (claude-code-ide-start-spec-instance-id spec)
                          (claude-code-ide-start-spec-provider spec)
                          (claude-code-ide-start-spec-resume-id spec))))
        (push record claude-code-ide-live-tests--starts)
        (write-region (format "%s %d %S\n" (format-time-string "%FT%T") (emacs-pid) record)
                      nil (claude-code-ide-live-tests--path "starts.txt") t 'silent)))))

(defun claude-code-ide-live-tests--note-stage (run stage)
  "Log that the handover RUN saved STAGE, with the time."
  (claude-code-ide-live-tests--log "handover %s stage %s"
                                   (claude-code-ide-handover--run-id run) stage))

(defun claude-code-ide-live-tests--claude-flags ()
  "Return the Claude Code flags of the live tests.
The model is sonnet.  The CLI may read the Codex sessions folder, and
it may use Read, Glob and Grep, and write the files of the handover
folder (the state summary), without a question.  It has no Bash, so it
reads the transcripts with the read tools.  Any other tool asks, and
`claude-code-ide-live-tests--approve-while' fails the test then.
CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS, when set and not empty, replaces
them."
  (let ((flags (getenv "CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS")))
    (if (and flags (not (string-empty-p flags)))
        flags
      (format "--model sonnet --add-dir %s --disallowedTools Bash --allowedTools %s"
              (shell-quote-argument (expand-file-name "sessions" (claude-code-ide-codex-home)))
              ;; One word; the quotes keep the shell off the parentheses
              "'Read,Glob,Grep,Edit(.handover/**),Write(.handover/**)'"))))

(defconst claude-code-ide-live-tests--unset-names
  '("ANTHROPIC_API_KEY" "OPENAI_API_KEY" "CLAUDECODE"
    "CLAUDE_CODE_CHILD_SESSION" "CLAUDE_CODE_ENTRYPOINT")
  "Variables that the Claude Code CLI of the live tests must not inherit.
An API key would bill the API instead of the subscription.  The
markers of a parent CLI make a child that saves no transcript.
CLAUDE_CODE_SSE_PORT is not here: the package sets it for each CLI,
and a name in `claude-code-ide-cli-environment-unset' would remove
that value too.")

(defun claude-code-ide-live-tests--environment-unset ()
  "Return `claude-code-ide-cli-environment-unset' with the names of the live tests."
  (let ((names (copy-sequence claude-code-ide-cli-environment-unset)))
    (dolist (name claude-code-ide-live-tests--unset-names)
      (unless (member name names)
        (setq names (append names (list name)))))
    names))

(defun claude-code-ide-live-tests--codex-flags (&optional bypass)
  "Return the Codex flags of the live tests.
BYPASS non-nil adds --dangerously-bypass-hook-trust.  The tools of the
claude-sessions server run without a question, and the reasoning effort
is low, to keep the turns short.  CLAUDE_CODE_IDE_LIVE_CODEX_FLAGS
replaces all but the bypass."
  (string-join
   (delq nil
         (list (and bypass "--dangerously-bypass-hook-trust")
               (or (getenv "CLAUDE_CODE_IDE_LIVE_CODEX_FLAGS")
                   (concat "-c 'model_reasoning_effort=\"low\"'"
                           " -c 'mcp_servers.claude-sessions.default_tools_approval_mode=\"approve\"'"))))
   " "))

(defun claude-code-ide-live-tests--start-time (pid)
  "Return the start time of the process PID as a float, or nil."
  (when-let* ((start (alist-get 'start (process-attributes pid))))
    (float-time start)))

(defvar claude-code-ide-live-tests--claim-wait 5
  "Seconds that a claim of a live folder waits at most for the claim lock.")

(defun claude-code-ide-live-tests--holder-text ()
  "Return the holder text of this Emacs: its process ID and start time.
Without a start time that can be read, the text is the process ID only."
  (let ((start (claude-code-ide-live-tests--start-time (emacs-pid))))
    (if start
        (format "%d %s" (emacs-pid) start)
      (format "%d" (emacs-pid)))))

(defun claude-code-ide-live-tests--lock-holder (lock)
  "Return the text of the holder file in the claim LOCK folder, or nil."
  (let ((file (expand-file-name "holder" lock)))
    (when (file-regular-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (string-trim (buffer-string))))))

(defun claude-code-ide-live-tests--claim-root (root)
  "Claim the live folder ROOT for this Emacs, or signal a `user-error'.
The file owner in ROOT holds the process ID and the start time of the
Emacs that uses ROOT.  Two daemons must not share one live folder: they
would share the registry, the inbox and the hooks.

The claim runs under a lock: the folder owner.lock in ROOT, made with
`make-directory' without parents, which fails when the folder exists.
So of two daemons that start at the same time, only one checks and
writes the owner at a time.  The lock lives only for the claim: the
claim removes it at its end, also after an error.

No claim removes a lock that exists, whatever its age or its holder.
A claim that finds the lock waits up to
`claude-code-ide-live-tests--claim-wait' seconds, and then signals a
`user-error' that names the lock, its holder file (the process ID and
start time of its Emacs, for people only), and the command that
removes it by hand after a crash."
  (let ((lock (expand-file-name "owner.lock" root))
        (deadline (+ (float-time) claude-code-ide-live-tests--claim-wait))
        (held nil))
    (while (not held)
      (condition-case nil
          (progn
            (make-directory lock)
            (setq held t))
        (file-already-exists
         (when (> (float-time) deadline)
           (user-error "The live folder %s is locked by another claim: %s (holder %s).  When no live test Emacs runs, remove it with: rm -r %s"
                       root lock (or (claude-code-ide-live-tests--lock-holder lock) "unknown")
                       (shell-quote-argument lock)))
         (sleep-for 0.1))))
    (unwind-protect
        (progn
          (write-region (claude-code-ide-live-tests--holder-text) nil
                        (expand-file-name "holder" lock) nil 'silent)
          (claude-code-ide-live-tests--claim-root-1 root))
      (ignore-errors (delete-directory lock t)))))

(defun claude-code-ide-live-tests--owner-runs-p (pid start)
  "Return non-nil when the owner of a live folder may still run.
PID is its process ID; START its start time, or nil when the owner file
has none.  The owner is gone only when no process has PID, or when the
process with PID started at a known other time.  An unknown start time,
in the file or now, counts as still running: the safe side."
  (let ((attributes (process-attributes pid)))
    (and attributes
         (let ((now (claude-code-ide-live-tests--start-time pid)))
           (or (null start) (null now) (< (abs (- now start)) 1.0))))))

(defun claude-code-ide-live-tests--check-root (root)
  "Signal a `user-error' when ROOT has files but no owner file.
Such a folder is no live folder, for example a folder of the user that
CLAUDE_CODE_IDE_LIVE_DIR names by mistake.  The claim lock owner.lock
does not count: a new folder has only the lock while it is claimed.
This only reads, so the setup calls it before it changes ROOT."
  (when (and (file-directory-p root)
             (not (file-exists-p (expand-file-name "owner" root)))
             (remove "owner.lock" (directory-files root nil directory-files-no-dot-files-regexp)))
    (user-error "%s has files and no owner file, so it is no live folder; choose an empty or new folder"
                root)))

(defun claude-code-ide-live-tests--claim-root-1 (root)
  "Claim ROOT for this Emacs; the caller holds the claim lock.
An owner that no longer runs (`claude-code-ide-live-tests--owner-runs-p')
is replaced.  A folder that has files but no owner file is no live
folder, for example a folder of the user that CLAUDE_CODE_IDE_LIVE_DIR
names: the claim refuses it.  When this Emacs cannot read its own start
time, it writes its process ID only."
  (let* ((file (expand-file-name "owner" root))
         (words (when (file-readable-p file)
                  (with-temp-buffer
                    (insert-file-contents file)
                    (split-string (buffer-string)))))
         (pid (and (car words) (string-match-p "\\`[0-9]+\\'" (car words))
                   (string-to-number (car words))))
         (start (and (cadr words) (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" (cadr words))
                     (string-to-number (cadr words)))))
    (claude-code-ide-live-tests--check-root root)
    (when (and pid (> pid 0) (/= pid (emacs-pid))
               (claude-code-ide-live-tests--owner-runs-p pid start))
      (user-error "Live folder %s belongs to Emacs %d; use CLAUDE_CODE_IDE_LIVE_DIR for another folder"
                  root pid))
    (write-region (concat (claude-code-ide-live-tests--holder-text) "\n") nil file nil 'silent)))

(defun claude-code-ide-live-tests-setup ()
  "Point the package at the live folder and turn on the session registry.
It runs once in each Emacs; a second call does nothing.  It runs only
where the live tests may run (`claude-code-ide-live-tests--live-p'):
elsewhere, for example in batch Emacs or in a person's Emacs, it
signals a `user-error' before it changes anything, because it changes
the options of the package, adds advice, and turns on the session
registry, whose recovery can start CLIs."
  (unless (claude-code-ide-live-tests--live-p)
    (user-error "The live test setup runs only in an own daemon with CLAUDE_CODE_IDE_LIVE_TESTS=1; see docs/live-tests.md"))
  (unless claude-code-ide-live-tests--setup-done
    (let ((root (claude-code-ide-live-tests--root)))
      ;; Refuse a folder that is no live folder before any change of it;
      ;; the claim checks again under its lock
      (claude-code-ide-live-tests--check-root root)
      (make-directory root t)
      (claude-code-ide-live-tests--claim-root root)
      (set-file-modes root #o700)
      ;; The CLIs get no API key and no marker of a parent CLI.  The test
      ;; checks only the names; it never reads a value.
      (setq claude-code-ide-cli-environment-unset (claude-code-ide-live-tests--environment-unset)
            claude-code-ide-codex-remove-openai-api-key t)
      (setq claude-code-ide-state-file (expand-file-name "state.json" root)
            claude-code-ide-session-registry-report-directory nil
            claude-code-ide-control-inbox-directory nil
            claude-code-ide-mcp-config-directory (expand-file-name "mcp-config" root)
            claude-code-ide-provider-file (expand-file-name "current-provider" root)
            claude-code-ide-mcp-server-coordinator-credential-file
            (expand-file-name "coordinator-credential" root)
            claude-code-ide-enable-mcp-server t
            claude-code-ide-mcp-server-port nil
            claude-code-ide-terminal-backend 'vterm
            claude-code-ide-show-backend-recommendation nil
            claude-code-ide-cli-extra-flags (claude-code-ide-live-tests--claude-flags)
            claude-code-ide-codex-extra-flags (claude-code-ide-live-tests--codex-flags t)
            claude-code-ide-handover-recover-at-start t)
      (advice-add 'claude-code-ide-mcp--lockfile-directory :override
                  #'claude-code-ide-live-tests--lockfile-directory)
      (advice-add 'claude-code-ide-codex-events--cached-trust :around
                  #'claude-code-ide-live-tests--cached-trust)
      (advice-add 'claude-code-ide--start-session :before #'claude-code-ide-live-tests--note-start)
      (advice-add 'claude-code-ide-handover--enter :before #'claude-code-ide-live-tests--note-stage)
      (add-hook 'claude-code-ide-event-functions #'claude-code-ide-live-tests--note-event)
      ;; The Emacs tools, as a user config has them: the approval test
      ;; calls one of them
      (claude-code-ide-emacs-tools-setup)
      (claude-code-ide-live-tests--log "setup in Emacs %d, folder %s" (emacs-pid) root)
      (setq claude-code-ide-live-tests--setup-done t)
      (claude-code-ide-session-registry-mode 1))))

;;; Waits

(defun claude-code-ide-live-tests--wait (predicate seconds &optional what)
  "Wait until PREDICATE returns non-nil, at most SECONDS, and return its value.
Timers and process output run during the wait.  WHAT names the
condition in the log when the wait ends without it."
  (let ((deadline (+ (float-time) seconds))
        (value (funcall predicate)))
    (while (and (not value) (< (float-time) deadline))
      (accept-process-output nil 0.2)
      (setq value (funcall predicate)))
    (unless value
      (claude-code-ide-live-tests--log "wait ended without %s after %s s" (or what "the condition") seconds))
    value))

(defun claude-code-ide-live-tests--event (instance-id kind &optional after)
  "Return the newest event KIND of INSTANCE-ID that came after the time AFTER."
  (cdr (cl-find-if (lambda (entry)
                     (and (or (null after) (> (car entry) after))
                          (equal (plist-get (cdr entry) :instance-id) instance-id)
                          (eq (plist-get (cdr entry) :event) kind)))
                   claude-code-ide-live-tests--events)))

(defun claude-code-ide-live-tests--reply (event)
  "Return the last message of the agent in the turn-end EVENT, or nil."
  (let ((data (plist-get event :data)))
    (or (claude-code-ide-handover--event-value data "last_assistant_message")
        (and (consp data) (alist-get 'last_assistant_message data)))))

(defun claude-code-ide-live-tests--wait-turn (instance-id after seconds)
  "Wait for a turn end of INSTANCE-ID after the time AFTER, and return its reply.
The reply is a string, or \"\" when the event has none.  nil means
that no turn ended in SECONDS."
  (when-let* ((event (claude-code-ide-live-tests--wait
                      (lambda () (claude-code-ide-live-tests--event instance-id 'turn-end after))
                      seconds (format "a turn end of %s" instance-id))))
    (let ((reply (or (claude-code-ide-live-tests--reply event) "")))
      (claude-code-ide-live-tests--log "turn end of %s: %s" instance-id
                                       (truncate-string-to-width (string-trim reply) 200))
      reply)))

(defun claude-code-ide-live-tests--state (instance-id)
  "Return (STATE REASON) of INSTANCE-ID now."
  (let ((state (claude-code-ide-instance-state instance-id)))
    (list (plist-get state :state) (plist-get state :reason))))

(defun claude-code-ide-live-tests--wait-state (instance-id states seconds)
  "Wait until INSTANCE-ID has one of STATES, and return that state.
STATES is a list of (STATE REASON).
A REASON of t matches any reason."
  (claude-code-ide-live-tests--wait
   (lambda ()
     (let ((now (claude-code-ide-live-tests--state instance-id)))
       (and (cl-some (lambda (wanted)
                       (and (eq (car wanted) (car now))
                            (or (eq (cadr wanted) t) (eq (cadr wanted) (cadr now)))))
                     states)
            now)))
   seconds (format "the state %S of %s" states instance-id)))

(defun claude-code-ide-live-tests--wait-handover (handover-id statuses seconds)
  "Wait until the handover HANDOVER-ID has one of STATUSES.
Return its status plist, or nil after SECONDS."
  (let ((result (claude-code-ide-live-tests--wait
                 (lambda ()
                   (let ((status (claude-code-ide-handover-status handover-id)))
                     (and (memq (plist-get status :status) statuses) status)))
                 seconds (format "the handover %s in %S" handover-id statuses))))
    (claude-code-ide-live-tests--log "handover %s: %S" handover-id
                                     (claude-code-ide-live-tests--brief-status
                                      (or result (claude-code-ide-handover-status handover-id))))
    result))

(defun claude-code-ide-live-tests--brief-status (status)
  "Return STATUS, a handover status plist, without its long values."
  (cl-loop for (key value) on status by #'cddr
           unless (memq key '(:document-hash))
           append (list key value)))

;;; Projects, files and instances

(defun claude-code-ide-live-tests--running-p (instance-id)
  "Return non-nil when INSTANCE-ID runs in this Emacs."
  (let ((instance (claude-code-ide-instance-by-id instance-id)))
    (and instance (claude-code-ide-instance-live-p instance))))

(defun claude-code-ide-live-tests--git (directory &rest args)
  "Run git with ARGS in DIRECTORY; signal an error when it fails."
  (let ((default-directory (file-name-as-directory directory)))
    (unless (eql 0 (apply #'call-process "git" nil nil nil args))
      (error "git %s failed in %s" (string-join args " ") directory))))

(defun claude-code-ide-live-tests--project (name)
  "Return the folder NAME of the live folder, a Git repository with one commit."
  (let ((dir (file-name-as-directory (claude-code-ide-live-tests--path name))))
    (unless (file-directory-p (expand-file-name ".git" dir))
      (make-directory dir t)
      (write-region (format "# %s\n\nA project of the claude-code-ide live tests.\n" name)
                    nil (expand-file-name "README.md" dir))
      (claude-code-ide-live-tests--git dir "init" "-q")
      (claude-code-ide-live-tests--git dir "add" "README.md")
      (claude-code-ide-live-tests--git dir "-c" "user.name=cci-test" "-c" "user.email=cci-test@example.invalid"
                                       "commit" "-q" "-m" "cci-test: first commit"))
    dir))

(defun claude-code-ide-live-tests--codeword (prefix)
  "Return a new codeword that starts with PREFIX, such as PREFIX-482."
  (format "%s-%03d" prefix (+ 100 (random 900))))

(defvar claude-code-ide-live-tests--created-files nil
  "The codeword files that the tests of this Emacs made and did not delete yet.")

(defun claude-code-ide-live-tests--write-secret (directory name codeword)
  "Write CODEWORD to the new file NAME in DIRECTORY, and return the file.
The file must not exist: the write uses the `excl' flag, so a file of
the user is never overwritten.  The file is recorded, so that
`claude-code-ide-live-tests--delete-secret' and the cleanup delete it,
and only it."
  (let ((file (expand-file-name name directory)))
    (write-region (concat "The codeword is " codeword ".\n") nil file nil 'silent nil 'excl)
    (push file claude-code-ide-live-tests--created-files)
    file))

(defun claude-code-ide-live-tests--delete-secret (file)
  "Delete the codeword FILE when a test of this Emacs made it.
A file that no test made, or that is no regular file now (for example a
link), stays."
  (when (member file claude-code-ide-live-tests--created-files)
    (when (and (file-regular-p file) (not (file-symlink-p file)))
      (delete-file file))
    (setq claude-code-ide-live-tests--created-files
          (delete file claude-code-ide-live-tests--created-files))))

(defun claude-code-ide-live-tests--launch (directory provider prompt)
  "Start PROVIDER in DIRECTORY with the first PROMPT, and return the instance ID."
  (let ((result (claude-code-ide-control-launch :directory directory :provider provider
                                                :prompt prompt)))
    (claude-code-ide-live-tests--log "launch %s in %s: %S" provider directory result)
    (should (eq (plist-get result :status) 'ok))
    (plist-get result :instance-id)))

(defun claude-code-ide-live-tests--stop (instance-id)
  "Stop INSTANCE-ID with the control operation, and return its result.
The stop asks no question in any terminal (the tests stop-asks-nothing
check it), so the tests stop as a coordinator does."
  (claude-code-ide-control-stop instance-id))

(defun claude-code-ide-live-tests--stop-all ()
  "Stop every instance of this Emacs, and wait until their terminals end."
  (dolist (instance (claude-code-ide-instances))
    (when (claude-code-ide-instance-live-p instance)
      (claude-code-ide-live-tests--stop (claude-code-ide-instance-id instance))))
  (claude-code-ide-live-tests--wait
   (lambda () (not (cl-some #'claude-code-ide-instance-live-p (claude-code-ide-instances))))
   30 "the end of all instances"))

(defun claude-code-ide-live-tests--cleanup ()
  "Stop every instance, and delete the codeword files that the tests made.
Only the files of `claude-code-ide-live-tests--created-files' go."
  (ignore-errors (claude-code-ide-live-tests--stop-all))
  (dolist (file (copy-sequence claude-code-ide-live-tests--created-files))
    (ignore-errors (claude-code-ide-live-tests--delete-secret file))))

(defun claude-code-ide-live-tests--buffer (instance-id)
  "Return the terminal buffer of INSTANCE-ID."
  (claude-code-ide-instance-buffer (claude-code-ide-instance-by-id instance-id)))

(defun claude-code-ide-live-tests--buffer-text (instance-id)
  "Return the text of the terminal buffer of INSTANCE-ID."
  (with-current-buffer (claude-code-ide-live-tests--buffer instance-id)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun claude-code-ide-live-tests--send-key (instance-id key)
  "Send KEY to the terminal of INSTANCE-ID, as a person would.
KEY is `return', `escape', `down' or a string."
  (with-current-buffer (claude-code-ide-live-tests--buffer instance-id)
    (pcase key
      ('return (claude-code-ide--terminal-send-return))
      ('escape (claude-code-ide--terminal-send-escape))
      ('down (if (eq claude-code-ide-terminal-backend 'vterm)
                 (vterm-send-down)
               (claude-code-ide--terminal-send-string "\e[B")))
      (_ (claude-code-ide--terminal-send-string key)))))

(defun claude-code-ide-live-tests--count (needle text)
  "Return how often NEEDLE occurs in TEXT."
  (let ((count 0) (start 0))
    (while (string-match (regexp-quote needle) text start)
      (setq count (1+ count) start (match-end 0)))
    count))

(defun claude-code-ide-live-tests--file-text (file)
  "Return the text of FILE, or \"\" when it cannot be read."
  (if (and (stringp file) (file-readable-p file))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (buffer-string))
    ""))

(defun claude-code-ide-live-tests--transcript (instance-id)
  "Return the transcript file of INSTANCE-ID, or nil."
  (let* ((instance (claude-code-ide-instance-by-id instance-id))
         (entry (claude-code-ide-session-registry-entry-of instance-id))
         (provider (or (and instance (claude-code-ide-instance-provider instance))
                       (and entry (claude-code-ide-session-registry-entry-provider entry))))
         (native (or (and instance (claude-code-ide-known-or-nil
                                    (claude-code-ide-instance-native-id instance)))
                     (and entry (claude-code-ide-session-registry-entry-session-id entry)))))
    (claude-code-ide-handover--transcript-file provider native entry)))

;;; Codex folder trust

(defun claude-code-ide-live-tests--codex-config-text ()
  "Return the text of the Codex config file."
  (claude-code-ide-live-tests--file-text (claude-code-ide-transcript--codex-config-file)))

(defun claude-code-ide-live-tests--folder-key (directory)
  "Return the key of DIRECTORY in the config files of the CLIs.
That is its true name, without the final slash: the CLIs resolve links,
for example /var to /private/var on macOS."
  (directory-file-name (file-truename (expand-file-name directory))))

(defun claude-code-ide-live-tests--codex-trusts-folder-p (directory)
  "Return non-nil when the Codex config has a trust entry for DIRECTORY."
  (string-search (format "[projects.%S]" (claude-code-ide-live-tests--folder-key directory))
                 (claude-code-ide-live-tests--codex-config-text)))

(defun claude-code-ide-live-tests--codex-trust-screen (text)
  "Return what the Codex screen TEXT shows at its start.
`dialog' for the folder trust dialog, `ready' for the composer (the
folder needs no question), else nil."
  (let ((flat (replace-regexp-in-string "[ \t\n]+" " " (or text ""))))
    (cond
     ((string-match-p "Trust and continue\\|Your trust decision will be saved\\|Trust this folder\\?"
                      flat)
      'dialog)
     ((string-match-p "Ask Codex to do anything" flat) 'ready))))

(defun claude-code-ide-live-tests--settled-trust-screen (read pause seconds)
  "Return what the Codex start screen settles on: `dialog', `ready', or nil.
READ is a function without arguments that returns the screen text.
Codex can draw its composer first and the folder trust dialog a moment
later, so a composer counts only when the screen still shows it, and no
dialog, PAUSE seconds later.  A dialog counts at once.  After SECONDS
without either, the result is nil."
  (let ((deadline (+ (float-time) seconds))
        (result nil))
    (while (and (not result) (< (float-time) deadline))
      (pcase (claude-code-ide-live-tests--codex-trust-screen (funcall read))
        ('dialog (setq result 'dialog))
        ('ready
         (when (> pause 0) (accept-process-output nil pause))
         (pcase (claude-code-ide-live-tests--codex-trust-screen (funcall read))
           ('dialog (setq result 'dialog))
           ('ready (setq result 'ready))))
        (_ (accept-process-output nil 0.2))))
    result))

(defun claude-code-ide-live-tests--ensure-codex-folder-trust (directory)
  "Make sure that Codex trusts DIRECTORY, or skip the test.
Codex asks one time for each new repository root, and it saves the
answer in its config file; no flag avoids the question.  A Codex that
reaches its composer without the question trusts the folder already.
With CLAUDE_CODE_IDE_LIVE_TRUST=1 the test answers \"Trust and
continue\" as a person, which writes [projects.\"DIRECTORY\"] to the
Codex config.  Without the variable, a folder that gets the question
skips the test."
  (unless (claude-code-ide-live-tests--codex-trusts-folder-p directory)
    (let* ((id (claude-code-ide-live-tests--launch directory 'codex nil))
           (seen (claude-code-ide-live-tests--settled-trust-screen
                  (lambda () (claude-code-ide-live-tests--buffer-text id))
                  3 60)))
      (claude-code-ide-live-tests--log "Codex start screen in %s: %S" directory seen)
      (unwind-protect
          (pcase seen
            ('ready (claude-code-ide-live-tests--log "Codex trusts %s already" directory))
            ('dialog
             (unless (claude-code-ide-live-tests--may-trust-p)
               (ert-skip (format "Codex does not trust %s; see docs/live-tests.md" directory)))
             (claude-code-ide-live-tests--send-key id 'return)
             (should (claude-code-ide-live-tests--wait
                      (lambda () (claude-code-ide-live-tests--codex-trusts-folder-p directory))
                      30 "the trust entry"))
             (claude-code-ide-live-tests--log "Codex trusts %s now (written by Codex)" directory))
            (_ (ert-fail (format "Codex showed neither its trust dialog nor its composer in %s"
                                 directory))))
        (claude-code-ide-live-tests--stop id)
        (claude-code-ide-live-tests--wait
         (lambda () (not (claude-code-ide-live-tests--running-p id)))
         30 "the end of the trust instance")))))

;;; Claude Code folder trust

(defun claude-code-ide-live-tests--may-trust-p ()
  "Return non-nil when the tests may answer the folder trust dialogs of the CLIs."
  (equal (getenv "CLAUDE_CODE_IDE_LIVE_TRUST") "1"))

(defun claude-code-ide-live-tests--claude-trusts-folder-p (directory)
  "Return non-nil when the Claude Code config trusts DIRECTORY itself.
The config file is that of `claude-code-ide-transcript--claude-config-file',
in CLAUDE_CONFIG_DIR when that is set."
  (let ((file (claude-code-ide-transcript--claude-config-file)))
    (when (file-readable-p file)
      (let* ((config (ignore-errors
                       (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8))
                           (insert-file-contents file))
                         (json-parse-buffer :object-type 'hash-table :false-object nil))))
             (projects (and (hash-table-p config) (gethash "projects" config)))
             (entry (and (hash-table-p projects)
                         (gethash (claude-code-ide-live-tests--folder-key directory) projects))))
        (and (hash-table-p entry) (gethash "hasTrustDialogAccepted" entry))))))

(defun claude-code-ide-live-tests--claude-trust-screen (text started)
  "Return what the Claude Code screen TEXT shows at its start.
`dialog' for the folder trust question.  `ready' when STARTED, that is
when the CLI sent its session start: Claude Code runs no hook in a
folder that it does not trust, so the folder needs no question.  Else
nil."
  (cond
   ((string-search "Yes, I trust this folder" (or text "")) 'dialog)
   (started 'ready)))

(defun claude-code-ide-live-tests--ensure-claude-folder-trust (directory)
  "Make sure that Claude Code trusts DIRECTORY, or skip the test.
A new folder gets the question \"Is this a project you created or one
you trust?\", whose default is \"No, exit\".  A CLI that starts without
the question (a session start comes) trusts the folder already.  With
CLAUDE_CODE_IDE_LIVE_TRUST=1 the test chooses \"Yes, I trust this
folder\" as a person, which writes the trust of DIRECTORY to the Claude
Code config.  Without the variable, a folder that gets the question
skips the test."
  (unless (claude-code-ide-live-tests--claude-trusts-folder-p directory)
    (let* ((id (claude-code-ide-live-tests--launch directory 'claude nil))
           (seen (claude-code-ide-live-tests--wait
                  (lambda () (claude-code-ide-live-tests--claude-trust-screen
                              (claude-code-ide-live-tests--buffer-text id)
                              (claude-code-ide-live-tests--event id 'session-start)))
                  60 "the Claude Code folder trust dialog or session start")))
      (unwind-protect
          (pcase seen
            ('ready (claude-code-ide-live-tests--log "Claude Code trusts %s already" directory))
            ('dialog
             (unless (claude-code-ide-live-tests--may-trust-p)
               (ert-skip (format "Claude Code does not trust %s; see docs/live-tests.md" directory)))
             ;; Down to the second choice, then Return.  The key goes only
             ;; when the dialog takes input, and Return only when the choice
             ;; shows as selected: a lone Escape would cancel, which exits.
             (should (claude-code-ide-live-tests--wait
                      (lambda ()
                        (accept-process-output nil 1)
                        (claude-code-ide-live-tests--send-key id 'down)
                        (accept-process-output nil 1)
                        (string-match-p "❯ *\\(?:[0-9]\\. \\)?Yes, I trust this folder"
                                        (claude-code-ide-live-tests--buffer-text id)))
                      30 "the choice Yes, I trust this folder"))
             (claude-code-ide-live-tests--send-key id 'return)
             (should (claude-code-ide-live-tests--wait
                      (lambda () (claude-code-ide-live-tests--claude-trusts-folder-p directory))
                      30 "the Claude Code trust entry"))
             (claude-code-ide-live-tests--log "Claude Code trusts %s now (written by Claude Code)"
                                              directory))
            (_ (ert-fail (format "Claude Code showed neither its trust dialog nor a session start in %s"
                                 directory))))
        (claude-code-ide-live-tests--stop id)
        (claude-code-ide-live-tests--wait
         (lambda () (not (claude-code-ide-live-tests--running-p id)))
         30 "the end of the trust instance")))))

;;; What the tests leave outside the live folder

(defun claude-code-ide-live-tests--claude-folder-name (directory)
  "Return the name of the transcript folder of DIRECTORY under projects/.
Claude Code puts a - for each character that is not a letter or a digit."
  (replace-regexp-in-string "[^A-Za-z0-9]" "-" (claude-code-ide-live-tests--folder-key directory)))

(defun claude-code-ide-live-tests-leftovers (&optional root)
  "Return what the live tests of ROOT left in the config folders of the CLIs.
ROOT defaults to the live folder.  The result is a plist:
- :codex-trust, the folders with a [projects.\"FOLDER\"] table in the
  Codex config;
- :claude-trust, the folders with a project entry with
  hasTrustDialogAccepted in the Claude Code config;
- :claude-transcripts, the transcript folders of Claude Code.
Each folder is in ROOT.  This only reads; docs/live-tests.md tells how
to remove them."
  (let* ((root (or root (claude-code-ide-live-tests--root)))
         (key (claude-code-ide-live-tests--folder-key root))
         (inside (lambda (folder) (string-prefix-p (concat key "/") folder)))
         (codex nil) (claude nil) (transcripts nil))
    (let ((text (claude-code-ide-live-tests--codex-config-text))
          (start 0))
      (while (string-match "^\\[projects\\.\"\\([^\"]+\\)\"\\]" text start)
        (when (funcall inside (match-string 1 text))
          (push (match-string 1 text) codex))
        (setq start (match-end 0))))
    (let ((file (claude-code-ide-transcript--claude-config-file)))
      (when (file-readable-p file)
        (when-let* ((config (ignore-errors
                              (with-temp-buffer
                                (let ((coding-system-for-read 'utf-8))
                                  (insert-file-contents file))
                                (json-parse-buffer :object-type 'hash-table :false-object nil))))
                    (projects (and (hash-table-p config) (gethash "projects" config)))
                    ((hash-table-p projects)))
          (maphash (lambda (folder entry)
                     (when (and (funcall inside folder) (hash-table-p entry)
                                (gethash "hasTrustDialogAccepted" entry))
                       (push folder claude)))
                   projects))))
    (let ((dir (expand-file-name "projects" (claude-code-ide-session-registry--claude-config-directory)))
          (prefix (concat (claude-code-ide-live-tests--claude-folder-name root) "-")))
      (when (file-directory-p dir)
        (dolist (name (directory-files dir))
          (when (string-prefix-p prefix name)
            (push (file-name-as-directory (expand-file-name name dir)) transcripts)))))
    (list :codex-trust (sort codex #'string<)
          :claude-trust (sort claude #'string<)
          :claude-transcripts (sort transcripts #'string<))))

(defun claude-code-ide-live-tests-show-leftovers ()
  "Show what the live tests left in the config folders of the CLIs.
See `claude-code-ide-live-tests-leftovers'.  It changes no file."
  (interactive)
  (let ((left (claude-code-ide-live-tests-leftovers)))
    (with-current-buffer (get-buffer-create "*Live test leftovers*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Codex config (%s), [projects.\"…\"] tables:\n"
                        (claude-code-ide-transcript--codex-config-file)))
        (dolist (folder (plist-get left :codex-trust)) (insert "  " folder "\n"))
        (insert (format "\nClaude Code config (%s), \"projects\" entries:\n"
                        (claude-code-ide-transcript--claude-config-file)))
        (dolist (folder (plist-get left :claude-trust)) (insert "  " folder "\n"))
        (insert "\nClaude Code transcript folders:\n")
        (dolist (folder (plist-get left :claude-transcripts)) (insert "  " folder "\n"))
        (insert "\nRemove them by hand when no CLI runs; see docs/live-tests.md.\n"))
      (display-buffer (current-buffer)))
    left))

(defun claude-code-ide-live-tests--claude-project (name)
  "Return the project NAME, trusted by Claude Code."
  (let ((dir (claude-code-ide-live-tests--project name)))
    (claude-code-ide-live-tests--ensure-claude-folder-trust dir)
    dir))

(defun claude-code-ide-live-tests--trusted-project (name)
  "Return the project NAME, trusted by both CLIs (see the trust functions)."
  (let ((dir (claude-code-ide-live-tests--project name)))
    (claude-code-ide-live-tests--ensure-claude-folder-trust dir)
    (claude-code-ide-live-tests--ensure-codex-folder-trust dir)
    dir))

;;; Handover steps

(defconst claude-code-ide-live-tests--turn-limit 300
  "Seconds that a test waits at most for one turn of an agent.")

(defconst claude-code-ide-live-tests--handover-limit 600
  "Seconds that a test waits at most for a handover to commit.")

(defun claude-code-ide-live-tests--read-secret-turn (instance-id directory file-name codeword label &optional prompt-only)
  "Make INSTANCE-ID read the file FILE-NAME in DIRECTORY, then delete it.
CODEWORD goes into the file.  LABEL starts the prompt.  The prompt
asks for the reply \"done\", so that the codeword is only in a tool
result.  It does not call the content secret: an agent then refuses to
say it later.  With PROMPT-ONLY, return the prompt and do nothing else."
  (let ((prompt (format "%s: Read the file %s with a tool. Then reply with the single word: done"
                        label file-name)))
    (if prompt-only
        prompt
      (claude-code-ide-live-tests--write-secret directory file-name codeword)
      (should (claude-code-ide-live-tests--submit-and-reply instance-id prompt))
      (claude-code-ide-live-tests--delete-secret (expand-file-name file-name directory)))))

(defun claude-code-ide-live-tests--first-turn (instance-id directory file-name codeword)
  "Wait for the first turn of INSTANCE-ID, then delete FILE-NAME.
That turn reads the file.
The file with CODEWORD in DIRECTORY must exist before the start."
  (ignore codeword)
  (should (claude-code-ide-live-tests--wait-turn instance-id 0 claude-code-ide-live-tests--turn-limit))
  (claude-code-ide-live-tests--delete-secret (expand-file-name file-name directory)))

(defun claude-code-ide-live-tests--request-id (label)
  "Return a new request ID that starts with LABEL.
A request ID is known for good, so each run needs its own."
  (format "%s-%s" label (format-time-string "%Y%m%dT%H%M%S")))

(defun claude-code-ide-live-tests--hand-over (source-id target-provider request-id)
  "Hand SOURCE-ID over to TARGET-PROVIDER as a coordinator does.
REQUEST-ID names the call.  Return the committed status."
  (let ((result (claude-code-ide-handover-session source-id target-provider
                                                  :request-id request-id)))
    (claude-code-ide-live-tests--log "handover of %s to %s: %S" source-id target-provider
                                     (claude-code-ide-live-tests--brief-status result))
    (should (eq (plist-get result :status) 'running))
    (let ((status (claude-code-ide-live-tests--wait-handover
                   (plist-get result :handover-id) '(committed cancelled failed needs-user)
                   claude-code-ide-live-tests--handover-limit)))
      (should (eq (plist-get status :status) 'committed))
      status)))

(defun claude-code-ide-live-tests--inside-p (file folder)
  "Return non-nil when FILE is FOLDER or in it, by their true names."
  (let ((file (directory-file-name (file-truename file)))
        (folder (directory-file-name (file-truename folder))))
    (or (equal file folder)
        (string-prefix-p (file-name-as-directory folder) file))))

(defun claude-code-ide-live-tests--read-path-p (path directory)
  "Return non-nil when the test may approve a read of PATH by a CLI in DIRECTORY.
PATH must be in the live folder, in a Claude Code transcript folder of
a folder in the live folder, or in the Codex sessions folder, by its
true name: a link counts by its target.  A relative PATH is in
DIRECTORY; without DIRECTORY, it counts as outside."
  (when (and (stringp path) (not (string-empty-p path))
             (or (file-name-absolute-p path) directory))
    (let* ((file (expand-file-name path directory))
           (root (claude-code-ide-live-tests--root))
           (projects (expand-file-name "projects" (claude-code-ide-session-registry--claude-config-directory))))
      (or (claude-code-ide-live-tests--inside-p file root)
          (claude-code-ide-live-tests--inside-p file (expand-file-name "sessions" (claude-code-ide-codex-home)))
          (and (claude-code-ide-live-tests--inside-p file projects)
               (string-prefix-p (concat (claude-code-ide-live-tests--claude-folder-name root) "-")
                                (file-relative-name (file-truename file) (file-truename projects))))))))

(defun claude-code-ide-live-tests--read-tool-p (tool &optional input directory)
  "Return non-nil when TOOL, a tool name of a CLI, only reads in a test folder.
These are the tools of the claude-sessions server (Claude Code names
them mcp__claude-sessions__NAME, Codex mcp__claude_sessions__NAME), and
Read, Glob and Grep on a path of `claude-code-ide-live-tests--read-path-p'.
INPUT is the tool input of the request: file_path for Read, path and
pattern for Glob, path for Grep; a missing path is DIRECTORY, the
folder of the CLI.  Every other tool, also Bash, is not."
  (let ((value (lambda (key) (claude-code-ide-handover--event-value input key))))
    (and (stringp tool)
         (pcase tool
           ((pred (string-match-p "\\`mcp__claude[-_]sessions__[a-z_]+\\'")) t)
           ("Read" (claude-code-ide-live-tests--read-path-p (funcall value "file_path") directory))
           ("Grep" (claude-code-ide-live-tests--read-path-p (or (funcall value "path") directory)
                                                            directory))
           ("Glob" (let ((base (or (funcall value "path") directory))
                         (pattern (funcall value "pattern")))
                     (and (claude-code-ide-live-tests--read-path-p base directory)
                          (stringp pattern)
                          (claude-code-ide-live-tests--read-path-p
                           (expand-file-name pattern (expand-file-name base directory))
                           directory)))))
         t)))

(defun claude-code-ide-live-tests--approval-tool (instance-id after)
  "Return the tool of the newest approval request of INSTANCE-ID, or nil.
Only requests after the float time AFTER count.  The tool is the
tool_name of the PermissionRequest hook."
  (when-let* ((event (claude-code-ide-live-tests--event instance-id 'approval-request after)))
    (claude-code-ide-handover--event-value (plist-get event :data) "tool_name")))

(defun claude-code-ide-live-tests--expect-approval (instance-id tool after seconds)
  "Check that the pending approval request of INSTANCE-ID names exactly TOOL.
The request is the newest PermissionRequest event after the float time
AFTER; the test waits for it at most SECONDS.  Any other tool, or no
request, fails the test, so that the person in the test never allows
a call that the test did not ask for.  Return non-nil."
  (let ((named (claude-code-ide-live-tests--wait
                (lambda () (claude-code-ide-live-tests--approval-tool instance-id after))
                seconds (format "an approval request of %s" instance-id))))
    (claude-code-ide-live-tests--log "%s asks to approve %S" instance-id named)
    (unless (equal named tool)
      (ert-fail (format "%s asks to approve %S, not %s" instance-id named tool)))
    t))

(defun claude-code-ide-live-tests--approval-on-screen-p (buffer)
  "Return non-nil when the terminal BUFFER shows an approval dialog now.
Only the screen counts (`claude-code-ide-codex--screen-text': the last
lines of the buffer), not the scrollback: an old dialog there would
make the test type its answer into the composer."
  (string-match-p "Do you want to proceed\\|Allow the"
                  (claude-code-ide-codex--screen-text buffer)))

(defun claude-code-ide-live-tests--approve-while (instance-id predicate seconds &optional after)
  "Wait until PREDICATE is non-nil, and approve the read tools of INSTANCE-ID.
A tool that only reads in a folder of the tests
\(`claude-code-ide-live-tests--read-tool-p') gets \"1. Yes\" from the
test, as a person, when the screen shows the dialog; the log has the
tool and the screen.  Any other tool or path fails the test: the test
never allows a write, a command, or a read elsewhere.  AFTER is the
float time from which approval requests count.  Return the value of
PREDICATE, or nil after SECONDS."
  (let* ((answered nil)
         (after (or after (float-time)))
         (instance (claude-code-ide-instance-by-id instance-id))
         (directory (and instance (claude-code-ide-known-or-nil
                                   (claude-code-ide-instance-project-root instance)))))
    (claude-code-ide-live-tests--wait
     (lambda ()
       (or (funcall predicate)
           (progn
             (when (equal (claude-code-ide-live-tests--state instance-id) '(waiting-for-user approval))
               (let ((entry (cl-find-if
                             (lambda (entry)
                               (and (> (car entry) after)
                                    (not (memq (cdr entry) answered))
                                    (equal (plist-get (cdr entry) :instance-id) instance-id)
                                    (eq (plist-get (cdr entry) :event) 'approval-request)))
                             claude-code-ide-live-tests--events))
                     (text (claude-code-ide-live-tests--buffer-text instance-id)))
                 (when entry
                   (let* ((data (plist-get (cdr entry) :data))
                          (tool (claude-code-ide-handover--event-value data "tool_name"))
                          (input (claude-code-ide-handover--event-value data "tool_input"))
                          (screen (replace-regexp-in-string
                                   "[ \t\n│]+" " " (substring text (max 0 (- (length text) 600))))))
                     (unless (claude-code-ide-live-tests--read-tool-p tool input directory)
                       (claude-code-ide-live-tests--log "%s asks for the tool %S with %S: %s"
                                                        instance-id tool input screen)
                       (ert-fail (format "%s asks for the tool %S with %S, which the test does not approve"
                                         instance-id tool input)))
                     (when (claude-code-ide-live-tests--approval-on-screen-p
                            (claude-code-ide-live-tests--buffer instance-id))
                       (claude-code-ide-live-tests--log
                        "%s: the test approves the read tool %s, as a person: %s"
                        instance-id tool screen)
                       (push (cdr entry) answered)
                       (claude-code-ide-live-tests--send-key instance-id "1"))))))
             nil)))
     seconds (format "a turn end of %s with approvals" instance-id))))

(defun claude-code-ide-live-tests--prompt-of (event)
  "Return the prompt text of the prompt-submit EVENT, trimmed, or nil."
  (when-let* ((prompt (claude-code-ide-handover--event-value (plist-get event :data) "prompt")))
    (and (stringp prompt) (string-trim prompt))))

(defun claude-code-ide-live-tests--delivery-time (instance-id text after)
  "Return the time of the prompt-submit event of INSTANCE-ID with TEXT, or nil.
Only events after the float time AFTER count.  The turn that answers
TEXT is the first turn end after this time: a turn end before it
belongs to an earlier prompt."
  (car (cl-find-if (lambda (entry)
                     (and (> (car entry) after)
                          (equal (plist-get (cdr entry) :instance-id) instance-id)
                          (eq (plist-get (cdr entry) :event) 'prompt-submit)
                          (equal (claude-code-ide-live-tests--prompt-of (cdr entry))
                                 (string-trim text))))
                   claude-code-ide-live-tests--events)))

(defun claude-code-ide-live-tests--wait-delivered (instance-id request-id text after)
  "Wait until the prompt TEXT of REQUEST-ID reached INSTANCE-ID; return the time.
The request status must be `delivered', and the time is that of its
prompt-submit event after the float time AFTER."
  (should (claude-code-ide-live-tests--wait
           (lambda () (eq (plist-get (claude-code-ide-control-request-status instance-id request-id)
                                     :result)
                          'delivered))
           claude-code-ide-live-tests--turn-limit (format "the delivery of %s" request-id)))
  (let ((time (claude-code-ide-live-tests--wait
               (lambda () (claude-code-ide-live-tests--delivery-time instance-id text after))
               30 (format "the prompt-submit event of %s" request-id))))
    (should time)
    time))

(defun claude-code-ide-live-tests--submit-and-reply (instance-id text)
  "Submit TEXT to INSTANCE-ID, and return the reply of the turn that answers it.
The prompt may wait in the inbox while the instance runs a turn.  The
turn is the first one that ends after the delivery of TEXT.  The read
tools of the turn are approved as a person; see
`claude-code-ide-live-tests--approve-while'."
  (let* ((start (float-time))
         (result (claude-code-ide-control-submit instance-id text :queue t))
         (request (plist-get result :request-id)))
    (should (memq (plist-get result :result) '(queued delivered)))
    (let ((delivered (claude-code-ide-live-tests--wait-delivered instance-id request text start)))
      (claude-code-ide-live-tests--approve-while
       instance-id (lambda () (claude-code-ide-live-tests--event instance-id 'turn-end delivered))
       claude-code-ide-live-tests--turn-limit delivered)
      (claude-code-ide-live-tests--wait-turn instance-id delivered claude-code-ide-live-tests--turn-limit))))

(defun claude-code-ide-live-tests--ask (instance-id question)
  "Submit QUESTION to INSTANCE-ID, and return the reply of its turn.
See `claude-code-ide-live-tests--submit-and-reply'."
  (claude-code-ide-live-tests--submit-and-reply instance-id question))

(defun claude-code-ide-live-tests--question (label file-name)
  "Return the question that asks for the codeword of FILE-NAME, with LABEL first.
The question does not hold the codeword."
  (format "%s: An earlier session in this chain read the file %s, which is gone now. Find its codeword in the earlier session as the handover document says, and reply with the codeword only."
          label file-name))

(defun claude-code-ide-live-tests--check-document (status codewords)
  "Check the document of the handover STATUS.
It exists, is private, has its hash, and holds none of CODEWORDS.
Return its text."
  (let* ((file (plist-get status :document))
         (text (claude-code-ide-live-tests--file-text file)))
    (should (file-exists-p file))
    (should (= (file-modes file) #o600))
    (should (equal (secure-hash 'sha256 text) (plist-get status :document-hash)))
    (dolist (word codewords)
      (should (= 0 (claude-code-ide-live-tests--count word text))))
    text))

(defun claude-code-ide-live-tests--target-ready (status)
  "Wait until the target of the handover STATUS ends its first turn.
The state summary must exist then.  Return the target ID."
  (let ((target (plist-get status :target-id)))
    ;; The first turn reads the document and the files that it names;
    ;; a read outside the project asks, and the test allows it
    (should (claude-code-ide-live-tests--approve-while
             target (lambda () (claude-code-ide-live-tests--event target 'turn-end))
             claude-code-ide-live-tests--turn-limit))
    (should (file-exists-p (expand-file-name
                            (concat (plist-get status :handover-id) "-state.md")
                            (file-name-directory (plist-get status :document)))))
    target))

(defun claude-code-ide-live-tests--session-tool-call (record)
  "Return the claude-sessions tool that the rollout RECORD calls, or nil.
RECORD is one parsed line of a Codex rollout, an alist.  Two records
are calls, read by their fields only, never by the text in them:
- an `item_completed' event whose item is an McpToolCall of the server
  claude-sessions with the status completed (Codex in code mode calls
  MCP tools from its exec tool, and records each call so);
- a `function_call' response item whose name is
  mcp__claude_sessions__TOOL (a direct call)."
  (let* ((payload (alist-get 'payload record))
         (kind (alist-get 'type payload)))
    (cond
     ((and (equal (alist-get 'type record) "event_msg") (equal kind "item_completed"))
      (let ((item (alist-get 'item payload)))
        (and (equal (alist-get 'type item) "McpToolCall")
             (equal (alist-get 'server item) "claude-sessions")
             (equal (alist-get 'status item) "completed")
             (stringp (alist-get 'tool item))
             (alist-get 'tool item))))
     ((and (equal (alist-get 'type record) "response_item") (equal kind "function_call"))
      (let ((name (alist-get 'name payload)))
        (and (stringp name)
             (string-match "\\`mcp__claude_sessions__\\([a-z_]+\\)\\'" name)
             (match-string 1 name)))))))

(defun claude-code-ide-live-tests--session-tool-calls (rollout)
  "Return the names of the claude-sessions tools that the Codex ROLLOUT calls.
See `claude-code-ide-live-tests--session-tool-call'.  A line that is no
JSON object counts as no call."
  (let ((names nil))
    (dolist (line (split-string (claude-code-ide-live-tests--file-text rollout) "\n" t))
      (when-let* ((record (ignore-errors
                            (json-parse-string line :object-type 'alist :array-type 'list
                                               :null-object nil :false-object nil)))
                  ((consp record))
                  (tool (claude-code-ide-live-tests--session-tool-call record)))
        (cl-pushnew tool names :test #'equal)))
    (nreverse names)))

(defun claude-code-ide-live-tests--document-tool-calls (calls)
  "Return the CALLS (claude-sessions tool names) that the handover document names.
These are get_session_outline and get_messages; another tool of the
server, such as list_sessions, does not read the earlier session."
  (cl-remove-if-not (lambda (tool) (member tool '("get_session_outline" "get_messages"))) calls))

;;; The handover tests

(ert-deftest claude-code-ide-live-test-handover-chain ()
  "CC -> Codex with claude-sessions, Codex -> CC, and the chain of three legs.
Each source reads a codeword with a tool and replies \"done\"; then the
file is deleted, so the codeword is only in a tool result of the source.
Leg 2 (Codex) must read it with the claude-sessions tools; leg 3 (CC)
reads the Codex rollout through the file reference."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (let* ((dir (claude-code-ide-live-tests--trusted-project "projA"))
           (word-1 (claude-code-ide-live-tests--codeword "MARMOT"))
           (word-2 (claude-code-ide-live-tests--codeword "HERON"))
           (claude-code-ide-handover-session-server "claude-sessions")
           (claude-code-ide-live-tests--assume-hook-trust t))
      (claude-code-ide-live-tests--write-secret dir "note-1.txt" word-1)
      (let* ((leg-1 (claude-code-ide-live-tests--launch
                     dir 'claude
                     (claude-code-ide-live-tests--read-secret-turn
                      nil dir "note-1.txt" word-1 "cci-test-L1 original task" t))))
        (claude-code-ide-live-tests--first-turn leg-1 dir "note-1.txt" word-1)
        ;; Leg 1 -> leg 2: CC -> Codex, with the session server
        (let* ((status-2 (claude-code-ide-live-tests--hand-over leg-1 'codex (claude-code-ide-live-tests--request-id "cci-test-L1-to-codex")))
               (doc-2 (claude-code-ide-live-tests--check-document status-2 (list word-1)))
               (leg-2 (claude-code-ide-live-tests--target-ready status-2)))
          (should (string-search "mcp__claude_sessions__get_session_outline" doc-2))
          (let ((reply (claude-code-ide-live-tests--ask
                        leg-2 (concat (claude-code-ide-live-tests--question "cci-test-L1q" "note-1.txt")
                                      " Use the claude-sessions tools that the document names, not the file.")))
                (rollout (claude-code-ide-live-tests--transcript leg-2)))
            (should (stringp reply))
            (should (string-search word-1 reply))
            (should (and (stringp rollout) (file-readable-p rollout)))
            ;; The detail came through the tools of claude-sessions
            (let ((calls (claude-code-ide-live-tests--session-tool-calls rollout)))
              (claude-code-ide-live-tests--log "case 1 rollout %s: claude-sessions calls %S" rollout calls)
              (should (claude-code-ide-live-tests--document-tool-calls calls))))
          ;; Leg 2 reads a second codeword; then leg 2 -> leg 3: Codex -> CC
          (claude-code-ide-live-tests--read-secret-turn leg-2 dir "note-2.txt" word-2 "cci-test-L3")
          (let* ((status-3 (claude-code-ide-live-tests--hand-over leg-2 'claude (claude-code-ide-live-tests--request-id "cci-test-L3-to-claude")))
                 ;; Leg 2 said codeword 1 in its answer, so only codeword 2
                 ;; must be absent: it is only in a tool result of leg 2
                 (doc-3 (claude-code-ide-live-tests--check-document status-3 (list word-2)))
                 (leg-3 (claude-code-ide-live-tests--target-ready status-3)))
            ;; The chain of three legs
            (should (= 1 (claude-code-ide-live-tests--count "cci-test-L1 original task" doc-3)))
            (should (= 1 (claude-code-ide-live-tests--count
                          (format "<!-- claude-code-ide-handover-document id=%s -->"
                                  (plist-get status-3 :handover-id))
                          doc-3)))
            (should (equal (mapcar (lambda (leg) (plist-get leg :provider))
                                   (claude-code-ide-session-registry-entry-legs
                                    (claude-code-ide-session-registry-entry-of leg-3)))
                           '(claude codex claude)))
            (should-not (cl-some (lambda (leg) (plist-get leg :pending))
                                 (claude-code-ide-session-registry-entry-legs
                                  (claude-code-ide-session-registry-entry-of leg-3))))
            (should (equal (claude-code-ide-session-registry-chain-current leg-1) leg-3))
            (should (equal (claude-code-ide-session-registry-chain-current leg-2) leg-3))
            (let ((reply (claude-code-ide-live-tests--ask
                          leg-3 (claude-code-ide-live-tests--question "cci-test-L3q" "note-2.txt"))))
              (should (stringp reply))
              (should (string-search word-2 reply))))))
      (claude-code-ide-live-tests--stop-all))))

(ert-deftest claude-code-ide-live-test-handover-file-reference ()
  "CC -> Codex without the session server: the target reads the transcript file."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (let* ((dir (claude-code-ide-live-tests--trusted-project "projA"))
           (word (claude-code-ide-live-tests--codeword "OSPREY"))
           (claude-code-ide-handover-session-server nil)
           (claude-code-ide-live-tests--assume-hook-trust t))
      (claude-code-ide-live-tests--write-secret dir "note-b.txt" word)
      (let ((source (claude-code-ide-live-tests--launch
                     dir 'claude
                     (claude-code-ide-live-tests--read-secret-turn
                      nil dir "note-b.txt" word "cci-test-L2 file reference" t))))
        (claude-code-ide-live-tests--first-turn source dir "note-b.txt" word)
        (let* ((status (claude-code-ide-live-tests--hand-over source 'codex (claude-code-ide-live-tests--request-id "cci-test-L2-to-codex")))
               (doc (claude-code-ide-live-tests--check-document status (list word)))
               (target (claude-code-ide-live-tests--target-ready status)))
          (should (= 0 (claude-code-ide-live-tests--count "mcp__" doc)))
          (should (= 0 (claude-code-ide-live-tests--count "claude-sessions" doc)))
          (should (string-search "Read it with: the file" doc))
          (let ((reply (claude-code-ide-live-tests--ask
                        target (claude-code-ide-live-tests--question "cci-test-L2q" "note-b.txt"))))
            (should (stringp reply))
            (should (string-search word reply))
            ;; The target read the file, not the session server.  A
            ;; missing rollout would hide its calls, so it must exist.
            (let ((rollout (claude-code-ide-live-tests--transcript target)))
              (should (and (stringp rollout) (file-readable-p rollout)))
              (should-not (claude-code-ide-live-tests--session-tool-calls rollout))))))
      (claude-code-ide-live-tests--stop-all))))

(ert-deftest claude-code-ide-live-test-handover-hooks-not-trusted ()
  "A coordinator handover to Codex without trusted hooks is refused, and nothing changes."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (let* ((dir (claude-code-ide-live-tests--project "projA"))
           (source (claude-code-ide-live-tests--launch dir 'claude nil))
           (claude-code-ide-live-tests--assume-hook-trust nil))
      (should (claude-code-ide-live-tests--wait
               (lambda () (claude-code-ide-session-registry-entry-of source)) 30 "the registry entry"))
      ;; The first call misses the cache and starts the check; the second
      ;; one, after the check, has the real result
      (dolist (attempt '(1 2))
        (let ((result (claude-code-ide-handover-session source 'codex
                                                        :request-id (format "cci-test-L5-%d" attempt))))
          (claude-code-ide-live-tests--log "hooks-not-trusted attempt %d: %S" attempt result)
          (should (eq (plist-get result :status) 'error))
          (should (eq (plist-get result :reason) 'hooks-not-trusted))
          (should (eq (plist-get (claude-code-ide-handover-status (format "cci-test-L5-%d" attempt))
                                 :reason)
                      'unknown-handover))
          (should (claude-code-ide-live-tests--running-p source))
          (should-not (claude-code-ide-session-registry-entry-handover
                       (claude-code-ide-session-registry-entry-of source)))
          ;; The real check of the first call fills the cache
          (let ((cached (claude-code-ide-live-tests--wait
                         (lambda () (gethash (claude-code-ide-codex-events--trust-key)
                                             claude-code-ide-codex-events--trust-cache))
                         30 "the result of the trust check")))
            (claude-code-ide-live-tests--log "trust cache after attempt %d: %S"
                                             attempt (plist-get cached :status))
            (should (eq (plist-get cached :status) 'untrusted)))))
      (claude-code-ide-live-tests--stop-all))))

(defun claude-code-ide-live-tests--start-stray (directory)
  "Start `sleep 900' in DIRECTORY outside Emacs, and return its process ID.
The shell that starts it ends at once, so the sleep is no child of Emacs."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory directory)))
      (call-process "sh" nil t nil "-c" "sleep 900 </dev/null >/dev/null 2>&1 & echo $!"))
    (string-to-number (string-trim (buffer-string)))))

(defun claude-code-ide-live-tests--own-strays-p (strays pid)
  "Return non-nil when STRAYS, of a handover status, are only the process PID.
The action `end' of a handover ends every stray, so the test may choose
it only when no other process is a stray."
  (equal (mapcar (lambda (stray) (plist-get stray :pid)) strays) (list pid)))

(ert-deftest claude-code-ide-live-test-handover-stray ()
  "A stray process in the worktree stops the handover with needs-user; end goes on."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (let* ((dir (claude-code-ide-live-tests--claude-project "projB"))
           (source (claude-code-ide-live-tests--launch dir 'claude "cci-test-L6 stray: reply with the single word ok"))
           (stray nil))
      (should (claude-code-ide-live-tests--wait-turn source 0 claude-code-ide-live-tests--turn-limit))
      (setq stray (claude-code-ide-live-tests--start-stray dir))
      (claude-code-ide-live-tests--log "stray sleep %d in %s" stray dir)
      (unwind-protect
          (let* ((result (claude-code-ide-handover-session source 'claude :request-id (claude-code-ide-live-tests--request-id "cci-test-L6")))
                 (id (plist-get result :handover-id))
                 (status (claude-code-ide-live-tests--wait-handover
                          id '(needs-user committed cancelled failed) 120)))
            (should (eq (plist-get status :status) 'needs-user))
            (should (eq (plist-get status :reason) 'strays))
            (should (eq (plist-get status :stage) 'source-stopped))
            (should (null (plist-get status :target-id)))
            (should-not (claude-code-ide-live-tests--running-p source))
            ;; `end' ends every stray of the handover: only the own sleep
            ;; may be one, else the test fails and ends nothing
            (unless (claude-code-ide-live-tests--own-strays-p (plist-get status :strays) stray)
              (ert-fail (format "The strays are not only the sleep %d: %S"
                                stray (plist-get status :strays))))
            (claude-code-ide-handover-resolve id 'end)
            (should (claude-code-ide-live-tests--wait
                     (lambda () (not (process-attributes stray))) 60 "the end of the stray"))
            (let ((final (claude-code-ide-live-tests--wait-handover
                          id '(committed cancelled failed needs-user)
                          claude-code-ide-live-tests--handover-limit)))
              (should (eq (plist-get final :status) 'committed))
              (claude-code-ide-live-tests--target-ready final)))
        (when (process-attributes stray)
          (signal-process stray 'SIGKILL)))
      (claude-code-ide-live-tests--stop-all))))

;;; Recovery after a crash of Emacs

(defvar claude-code-ide-live-tests--kill-stage nil
  "Stage at whose save the recovery test ends this Emacs with SIGKILL, or nil.")

(defun claude-code-ide-live-tests--recovery-file ()
  "Return the file that passes the state of the recovery test to the next Emacs."
  (claude-code-ide-live-tests--path "recovery.eld"))

(defun claude-code-ide-live-tests--kill-at-stage (function run stage)
  "Call FUNCTION with RUN and STAGE; after the save of the kill stage, kill Emacs.
The state of the test goes to the recovery file first."
  (let ((saved (funcall function run stage)))
    (when (and saved (eq stage claude-code-ide-live-tests--kill-stage))
      (with-temp-file (claude-code-ide-live-tests--recovery-file)
        (prin1 (list :handover-id (claude-code-ide-handover--run-id run)
                     :source-id (claude-code-ide-handover--run-source-id run)
                     :target-id (claude-code-ide-handover--run-target-id run)
                     :target-native-id (claude-code-ide-handover--run-target-native-id run)
                     ;; Did the target save its conversation before the crash?
                     :target-saved (let ((file (and (claude-code-ide-handover--run-target-id run)
                                                    (claude-code-ide-live-tests--transcript
                                                     (claude-code-ide-handover--run-target-id run)))))
                                     (and file (file-readable-p file) t))
                     :stage stage
                     :codeword (get 'claude-code-ide-live-tests--kill-stage 'codeword)
                     :emacs-pid (emacs-pid))
               (current-buffer)))
      (claude-code-ide-live-tests--log "SIGKILL to Emacs %d at the stage %s" (emacs-pid) stage)
      (signal-process (emacs-pid) 'SIGKILL))
    saved))

(ert-deftest claude-code-ide-live-test-recovery-1-kill ()
  "Part 1 of the recovery test: kill Emacs between source-stopped and committed.
It runs only with CLAUDE_CODE_IDE_LIVE_KILL set to a stage, for example
target-identified, because it ends this Emacs.  Part 2 runs in the next
Emacs."
  :tags '(:live :kill)
  (claude-code-ide-live-tests--live
    (skip-unless (member (getenv "CLAUDE_CODE_IDE_LIVE_KILL")
                         '("source-stopped" "document-written" "target-started" "target-identified" "delivered")))
    (claude-code-ide-live-tests--stop-all)
    (let* ((dir (claude-code-ide-live-tests--claude-project "projC"))
           (word (claude-code-ide-live-tests--codeword "BADGER")))
      (claude-code-ide-live-tests--write-secret dir "note-7.txt" word)
      (let ((source (claude-code-ide-live-tests--launch
                     dir 'claude
                     (claude-code-ide-live-tests--read-secret-turn
                      nil dir "note-7.txt" word "cci-test-L7 recovery" t))))
        (claude-code-ide-live-tests--first-turn source dir "note-7.txt" word)
        (when (file-exists-p (claude-code-ide-live-tests--recovery-file))
          (delete-file (claude-code-ide-live-tests--recovery-file)))
        (setq claude-code-ide-live-tests--kill-stage (intern (getenv "CLAUDE_CODE_IDE_LIVE_KILL")))
        (put 'claude-code-ide-live-tests--kill-stage 'codeword word)
        (advice-add 'claude-code-ide-handover--enter :around #'claude-code-ide-live-tests--kill-at-stage)
        (unwind-protect
            (let ((result (claude-code-ide-handover-session source 'claude :request-id (claude-code-ide-live-tests--request-id "cci-test-L7"))))
              (should (eq (plist-get result :status) 'running))
              ;; This Emacs ends at the kill stage; a wait that ends means a failure
              (claude-code-ide-live-tests--wait-handover
               (plist-get result :handover-id) '(committed cancelled failed needs-user)
               claude-code-ide-live-tests--handover-limit)
              (ert-fail "Emacs was not killed at the stage"))
          (advice-remove 'claude-code-ide-handover--enter #'claude-code-ide-live-tests--kill-at-stage)
          (setq claude-code-ide-live-tests--kill-stage nil))))))

(defun claude-code-ide-live-tests--cli-processes (native-id)
  "Return the process IDs of the CLIs whose command line names NATIVE-ID.
A CLI is a process with a word of its command line whose file name is
claude or codex, also after a launcher such as node .../bin/claude."
  (cl-remove-if-not
   (lambda (pid)
     (let ((args (alist-get 'args (process-attributes pid))))
       (and (stringp args)
            (string-search native-id args)
            (string-match-p "\\(?:\\`\\|[[:space:]]\\)\\(?:\\S-*/\\)?\\(?:claude\\|codex\\)\\(?:[[:space:]]\\|\\'\\)"
                            args))))
   (list-system-processes)))

(ert-deftest claude-code-ide-live-test-recovery-2-after-kill ()
  "Part 2 of the recovery test: the new Emacs starts only the target.
The registry mode turns on at the start of this Emacs, and its recovery
runs in the first idle moment, before this test.  The test checks that
the source never starts again, that the target runs with its instance
ID, that the handover commits, and that the target has the work."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    ;; The recovery started the target already; it must still run
    :keep-instances
    (skip-unless (file-exists-p (claude-code-ide-live-tests--recovery-file)))
    (let* ((state (with-temp-buffer
                    (insert-file-contents (claude-code-ide-live-tests--recovery-file))
                    (read (current-buffer))))
           (id (plist-get state :handover-id))
           (source (plist-get state :source-id))
           (target (plist-get state :target-id))
           (source-entry (claude-code-ide-session-registry-entry-of source)))
      (claude-code-ide-live-tests--log "recovery state: %S" state)
      (should-not (equal (plist-get state :emacs-pid) (emacs-pid)))
      (let ((final (claude-code-ide-live-tests--wait-handover
                    id '(committed cancelled failed needs-user) claude-code-ide-live-tests--handover-limit)))
        (should (eq (plist-get final :status) 'committed))
        ;; Before target-started, the target has no ID yet
        (if target
            (should (equal (plist-get final :target-id) target))
          (setq target (plist-get final :target-id))))
      ;; Only the target started in this Emacs
      (let ((starts (cl-remove-if-not (lambda (record) (equal (cadr record) (emacs-pid)))
                                      (claude-code-ide-live-tests--starts-on-disk))))
        (claude-code-ide-live-tests--log "starts in this Emacs: %S" starts)
        (should (cl-every (lambda (record) (equal (car (nth 2 record)) target)) starts))
        (should starts)
        ;; A target whose conversation was never saved cannot be resumed:
        ;; it starts fresh with its own session ID, and no resume ID
        (when (and (plist-get state :target-native-id) (not (plist-get state :target-saved)))
          (should (cl-every (lambda (record) (null (nth 2 (nth 2 record)))) starts))
          (let ((native (plist-get state :target-native-id)))
            (should (cl-some (lambda (pid)
                               (string-search (concat "--session-id " native)
                                              (alist-get 'args (process-attributes pid))))
                             (claude-code-ide-live-tests--cli-processes native)))
            (claude-code-ide-live-tests--log "the target started fresh with --session-id %s" native))))
      (should-not (claude-code-ide-instance-by-id source))
      (should (claude-code-ide-live-tests--running-p target))
      (should-not (claude-code-ide-live-tests--cli-processes
                   (claude-code-ide-session-registry-entry-session-id source-entry)))
      (should (equal (claude-code-ide-session-registry-chain-current source) target))
      (claude-code-ide-live-tests--target-ready (claude-code-ide-handover-status id))
      (let ((reply (claude-code-ide-live-tests--ask
                    target (claude-code-ide-live-tests--question "cci-test-L7q" "note-7.txt"))))
        (should (stringp reply))
        (should (string-search (plist-get state :codeword) reply)))
      (rename-file (claude-code-ide-live-tests--recovery-file)
                   (concat (claude-code-ide-live-tests--recovery-file) ".done") t)
      (claude-code-ide-live-tests--stop-all))))

(defun claude-code-ide-live-tests--starts-on-disk ()
  "Return the starts in starts.txt of the live folder, as (TIME PID RECORD)."
  (let ((file (claude-code-ide-live-tests--path "starts.txt")))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (cl-loop for line in (split-string (buffer-string) "\n" t)
                 for parts = (split-string line " ")
                 collect (list (car parts) (string-to-number (cadr parts))
                               (car (read-from-string
                                     (string-join (cddr parts) " ")))))))))

;;; Codex dialogs in each terminal backend

(defun claude-code-ide-live-tests--backend-ready (backend)
  "Load BACKEND, and make an invisible GUI frame; skip when that cannot be done.
ghostel draws only in a window of a real frame, not in the dummy frame
of a daemon.  Each terminal of the dialog tests shows in a window of
that frame, as it does for a person, so its size is that of the window."
  (pcase backend
    ('vterm (unless (require 'vterm nil t) (ert-skip "No vterm")))
    ('eat (unless (require 'eat nil t) (ert-skip "No eat")))
    ('ghostel (unless (require 'ghostel nil t) (ert-skip "No ghostel"))))
  ;; Each terminal shows in a window of this frame, as for a person
  (unless (cl-some (lambda (frame) (memq (framep frame) '(ns x w32 pgtk)))
                   (frame-list))
    (unless (ignore-errors
              (make-frame '((window-system . ns) (visibility . nil)
                            (width . 120) (height . 40))))
      (ert-skip "No GUI frame"))))

(defmacro claude-code-ide-live-tests--with-backend (backend &rest body)
  "Run BODY with the terminal BACKEND, once BACKEND is ready."
  (declare (indent 1))
  `(let ((claude-code-ide-terminal-backend ,backend))
     (claude-code-ide-live-tests--backend-ready ,backend)
     ,@body))

(defun claude-code-ide-live-tests--show (instance-id)
  "Show the terminal of INSTANCE-ID in a window of a real frame, when there is one."
  (when-let* ((frame (cl-find-if (lambda (frame) (memq (framep frame) '(ns x w32 pgtk)))
                                 (frame-list)))
              (buffer (claude-code-ide-live-tests--buffer instance-id)))
    ;; The start of the instance may have split the frame (a side
    ;; window): the terminal gets the whole frame, as one window
    (with-selected-frame frame
      (let ((window (frame-first-window frame)))
        (ignore-errors
          (let ((ignore-window-parameters t))
            (delete-other-windows window)))
        (set-window-buffer window buffer)))))

(defvar claude-code-ide-live-tests--show-terminals t
  "Non-nil: a dialog test shows the terminal in a window of the GUI frame.
nil: the terminal shows in no window, as a buffer in the background.")

(defun claude-code-ide-live-tests--hide-buffer (buffer)
  "Take BUFFER out of each window that shows it, in every frame.
A window that is dedicated to BUFFER (the package shows a terminal so)
goes; when it is the only window of its frame, it stops being dedicated
and shows another buffer.  Any other window shows another buffer."
  (let ((other (get-buffer-create "*scratch*")))
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (and (window-dedicated-p window)
                   (ignore-errors (delete-window window) t))
        (set-window-dedicated-p window nil)
        (set-window-buffer window other)))))

(defun claude-code-ide-live-tests--place (instance-id)
  "Show the terminal of INSTANCE-ID, or hide it.
The choice is `claude-code-ide-live-tests--show-terminals'."
  (if claude-code-ide-live-tests--show-terminals
      (claude-code-ide-live-tests--show instance-id)
    (let ((buffer (claude-code-ide-live-tests--buffer instance-id)))
      (claude-code-ide-live-tests--hide-buffer buffer)
      (should-not (get-buffer-window-list buffer nil t)))))

(defun claude-code-ide-live-tests--screen (instance-id)
  "Return the screen text of INSTANCE-ID, with runs of blanks as one space."
  (string-trim
   (replace-regexp-in-string
    "[ \t]+" " " (claude-code-ide-codex--screen-text (claude-code-ide-live-tests--buffer instance-id)))))

(defun claude-code-ide-live-tests--dialog-prompt (marker)
  "Return the prompt with MARKER that a dialog test submits."
  (format "%s: reply with the single word queued" marker))

(defun claude-code-ide-live-tests--dialog-check (instance-id kind state marker)
  "Check that INSTANCE-ID shows the dialog KIND and gets no typed text.
INSTANCE-ID must be in STATE.
STATE is (STATE REASON).  The submit of a prompt that holds MARKER
while the dialog shows must queue it, and the terminal must not show
it.  Return the submit result."
  (claude-code-ide-live-tests--place instance-id)
  (let ((found (claude-code-ide-live-tests--wait
                (lambda () (eq (claude-code-ide-codex-screen-dialog
                                (claude-code-ide-live-tests--buffer instance-id))
                               kind))
                120 (format "the dialog %s" kind))))
    (claude-code-ide-live-tests--log
     "%s: the screen (%s), read as %S: %S" instance-id kind
     (claude-code-ide-codex-screen-dialog (claude-code-ide-live-tests--buffer instance-id))
     (claude-code-ide-live-tests--screen instance-id))
    (should found))
  (should (equal (claude-code-ide-live-tests--wait-state instance-id (list state) 30) state))
  (let* ((before (claude-code-ide-live-tests--buffer-text instance-id))
         (result (claude-code-ide-control-submit
                  instance-id (claude-code-ide-live-tests--dialog-prompt marker) :queue t)))
    (claude-code-ide-live-tests--log "%s: submit in the dialog %s: %S" instance-id kind result)
    (should (eq (plist-get result :result) 'queued))
    (accept-process-output nil 3)
    (should-not (string-search marker (claude-code-ide-live-tests--buffer-text instance-id)))
    (should (eq (claude-code-ide-codex-screen-dialog (claude-code-ide-live-tests--buffer instance-id))
                kind))
    (claude-code-ide-live-tests--log "%s: the screen kept the dialog %s (%d -> %d characters)"
                                     instance-id kind (length before)
                                     (length (claude-code-ide-live-tests--buffer-text instance-id)))
    result))

(defun claude-code-ide-live-tests--dialogs (backend)
  "Check the folder trust, hooks review and approval dialogs of Codex in BACKEND."
  (claude-code-ide-live-tests--stop-all)
  (claude-code-ide-live-tests--with-backend backend
    (let ((untrusted (claude-code-ide-live-tests--project (format "dialogs-untrusted-%s" backend)))
          (trusted (claude-code-ide-live-tests--project "projA"))
          (tag (format "cci-test-L-%s" backend)))
      (claude-code-ide-live-tests--ensure-codex-folder-trust trusted)
      ;; 1. Folder trust: a new repository root.  Nobody answers it.
      (should-not (claude-code-ide-live-tests--codex-trusts-folder-p untrusted))
      (let ((id (claude-code-ide-live-tests--launch untrusted 'codex nil)))
        (claude-code-ide-live-tests--dialog-check
         id 'folder-trust '(waiting-for-user dialog) (concat tag "-trust"))
        (claude-code-ide-live-tests--stop id))
      (should-not (claude-code-ide-live-tests--codex-trusts-folder-p untrusted))
      (claude-code-ide-live-tests--stop-all)
      ;; 2. Hooks review: the launch gets the hooks, but Codex does not
      ;; trust them (no bypass).  Nobody answers it.
      (let* ((claude-code-ide-live-tests--assume-hook-trust t)
             (claude-code-ide-codex-extra-flags (claude-code-ide-live-tests--codex-flags nil))
             (id (claude-code-ide-live-tests--launch trusted 'codex nil)))
        (claude-code-ide-live-tests--dialog-check
         id 'hooks-review '(waiting-for-user dialog) (concat tag "-hooks"))
        (claude-code-ide-live-tests--stop id))
      (claude-code-ide-live-tests--stop-all)
      ;; 3. Approval: an MCP tool that needs an approval
      (claude-code-ide-live-tests--approval-dialog trusted tag)
      (claude-code-ide-live-tests--stop-all))))

(defun claude-code-ide-live-tests--approval-dialog (directory tag)
  "Check the MCP approval dialog of Codex in DIRECTORY; TAG starts the prompts.
The dialog shows, and the state is waiting-for-user/approval while it
shows (the test reads it five times in five seconds).  A submit queues
its prompt and types nothing.  The pending request must name the tool
that the test asked for.  After the person allows the call, the tool
ends and the state is no longer an approval; then the queued prompt
goes out, and its own turn answers it."
  (let* ((claude-code-ide-mcp-allowed-tools nil)
         (tool "mcp__emacs_tools__claude_code_ide_mcp_project_info")
         (launched (float-time))
         (id (claude-code-ide-live-tests--launch
              directory 'codex
              (concat tag "-approval: call the MCP tool " tool
                      " one time (it is in ALL_TOOLS), then reply with the single word called"))))
    (let* ((start (float-time))
           (result (claude-code-ide-live-tests--dialog-check
                    id 'approval '(waiting-for-user approval) (concat tag "-queued")))
           (request (plist-get result :request-id))
           (text (claude-code-ide-live-tests--dialog-prompt (concat tag "-queued"))))
      ;; The state stays an approval while the dialog waits
      (dotimes (_ 5)
        (accept-process-output nil 1)
        (should (equal (claude-code-ide-live-tests--state id) '(waiting-for-user approval))))
      (unless claude-code-ide-live-tests--show-terminals
        (should-not (get-buffer-window-list (claude-code-ide-live-tests--buffer id) nil t)))
      ;; The person allows only the call that the test asked for:
      ;; the pending request must name that tool, else the test fails
      (claude-code-ide-live-tests--expect-approval id tool launched 30)
      ;; The person allows the call; the tool ends, then the first turn
      (let ((allowed (float-time)))
        (claude-code-ide-live-tests--send-key id 'return)
        (should (claude-code-ide-live-tests--wait
                 (lambda () (or (claude-code-ide-live-tests--event id 'tool-end allowed)
                                (claude-code-ide-live-tests--event id 'turn-end allowed)))
                 claude-code-ide-live-tests--turn-limit "the end of the allowed tool"))
        (should-not (equal (claude-code-ide-live-tests--state id) '(waiting-for-user approval))))
      (should (claude-code-ide-live-tests--wait-turn id 0 claude-code-ide-live-tests--turn-limit))
      ;; Then the queued prompt goes out, and its own turn answers it:
      ;; only a turn end after its delivery counts
      (let ((delivered (claude-code-ide-live-tests--wait-delivered id request text start)))
        (should (claude-code-ide-live-tests--wait-turn
                 id delivered claude-code-ide-live-tests--turn-limit))))
    (claude-code-ide-live-tests--stop id)))

(ert-deftest claude-code-ide-live-test-codex-approval-eat-no-window ()
  "The Codex approval dialog in an eat buffer that shows in no window.
Such a buffer keeps only the end of the dialog; the dialog must still
read as an approval, and the state must stay waiting-for-user/approval
until the person allows the call and the tool ends."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--live
    (unless (require 'eat nil t) (ert-skip "No eat"))
    ;; No GUI frame, as in a daemon that a person never opened: the
    ;; terminal never gets the size of a window.  A dialog test that
    ;; needs a frame makes a new one.
    (dolist (frame (frame-list))
      (when (memq (framep frame) '(ns x w32 pgtk))
        (delete-frame frame t)))
    (let ((claude-code-ide-terminal-backend 'eat)
          (claude-code-ide-live-tests--show-terminals nil)
          (trusted (claude-code-ide-live-tests--project "projA")))
      (claude-code-ide-live-tests--ensure-codex-folder-trust trusted)
      (claude-code-ide-live-tests--approval-dialog trusted "cci-test-L-eat-hidden"))))

(ert-deftest claude-code-ide-live-test-codex-dialogs-vterm ()
  "The Codex dialogs in vterm: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--dialogs 'vterm)))

(ert-deftest claude-code-ide-live-test-codex-dialogs-eat ()
  "The Codex dialogs in eat: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--dialogs 'eat)))

(ert-deftest claude-code-ide-live-test-codex-dialogs-ghostel ()
  "The Codex dialogs in ghostel, in an invisible GUI frame: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--dialogs 'ghostel)))

;;; Handovers in ghostel

(defun claude-code-ide-live-tests--cli-pid (instance-id)
  "Return the PID of the CLI of INSTANCE-ID that the start recorded.
The PID must be known and its process must run."
  (let ((pid (claude-code-ide-instance-pid (claude-code-ide-instance-by-id instance-id))))
    (claude-code-ide-live-tests--log "%s: the recorded CLI PID is %S" instance-id pid)
    (should (integerp pid))
    (should (process-attributes pid))
    pid))

(defun claude-code-ide-live-tests--wait-gone (pid)
  "Wait until the process PID has ended; fail the test when it still runs."
  (should (claude-code-ide-live-tests--wait
           (lambda () (not (process-attributes pid)))
           20 (format "the end of the source CLI %d" pid)))
  (claude-code-ide-live-tests--log "the source CLI %d has ended" pid))

(ert-deftest claude-code-ide-live-test-handover-ghostel-sources-end ()
  "In ghostel, a handover ends its source CLI: CC -> Codex, then Codex -> CC.
In the user's Emacs (ghostel 20261111), the descriptor had no PID for
any ghostel instance: the handover stop found no process, reported
stopped, and committed while the source CLI ran on."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--with-backend 'ghostel
      (let* ((dir (claude-code-ide-live-tests--trusted-project "projA"))
             (claude-code-ide-live-tests--assume-hook-trust t)
             (source (claude-code-ide-live-tests--launch
                      dir 'claude "cci-test-L8 ghostel: reply with the single word ok")))
        (claude-code-ide-live-tests--show source)
        (should (claude-code-ide-live-tests--wait-turn source 0 claude-code-ide-live-tests--turn-limit))
        ;; CC -> Codex: the CC CLI ends
        (let* ((cc-pid (claude-code-ide-live-tests--cli-pid source))
               (status (claude-code-ide-live-tests--hand-over
                        source 'codex (claude-code-ide-live-tests--request-id "cci-test-L8-to-codex")))
               (codex (plist-get status :target-id)))
          (claude-code-ide-live-tests--wait-gone cc-pid)
          (should-not (claude-code-ide-live-tests--running-p source))
          (claude-code-ide-live-tests--target-ready status)
          ;; Codex -> CC: the Codex CLI ends
          (let* ((codex-pid (claude-code-ide-live-tests--cli-pid codex))
                 (status-2 (claude-code-ide-live-tests--hand-over
                            codex 'claude (claude-code-ide-live-tests--request-id "cci-test-L8-to-claude"))))
            (claude-code-ide-live-tests--wait-gone codex-pid)
            (should-not (claude-code-ide-live-tests--running-p codex))
            (claude-code-ide-live-tests--target-ready status-2)
            (claude-code-ide-live-tests--cli-pid (plist-get status-2 :target-id))))))))

;;; The stop asks nothing

(defun claude-code-ide-live-tests--stop-asks-nothing (backend provider)
  "Check that a stop ends PROVIDER in BACKEND without a question.
The stop is `claude-code-ide-control-stop'.
A coordinator stops an instance; nobody is there to answer a question
such as \"Buffer has a running process; kill it?\".  In a daemon such a
question blocks Emacs."
  (claude-code-ide-live-tests--stop-all)
  (claude-code-ide-live-tests--with-backend backend
    (let* ((dir (claude-code-ide-live-tests--project "projA"))
           (questions nil)
           (id (progn
                 (when (eq provider 'codex)
                   (claude-code-ide-live-tests--ensure-codex-folder-trust dir))
                 (claude-code-ide-live-tests--launch dir provider nil)))
           (process (get-buffer-process (claude-code-ide-live-tests--buffer id))))
      (claude-code-ide-live-tests--log "%s in %s: the query flag of the terminal process is %S"
                                       provider backend (process-query-on-exit-flag process))
      (accept-process-output nil 3)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (push prompt questions) (error "cci-test: a question: %s" prompt)))
                ((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt questions) (error "cci-test: a question: %s" prompt))))
        (let ((result (condition-case err
                          (claude-code-ide-control-stop id)
                        (error (list :status 'signal :error err)))))
          (claude-code-ide-live-tests--log "%s in %s: stop %S, questions %S" provider backend result questions)
          (unwind-protect
              (progn
                (should-not questions)
                (should (eq (plist-get result :status) 'ok))
                (should (claude-code-ide-live-tests--wait
                         (lambda () (not (process-live-p process))) 15 "the end of the CLI")))
            (let ((kill-buffer-query-functions nil))
              (when (claude-code-ide-live-tests--running-p id)
                (claude-code-ide-control-stop id)))))))))

(ert-deftest claude-code-ide-live-test-stop-asks-nothing-eat ()
  "A stop of a Codex instance in eat asks no question."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--stop-asks-nothing 'eat 'codex)))

(ert-deftest claude-code-ide-live-test-stop-asks-nothing-ghostel ()
  "A stop of a Codex instance in ghostel asks no question."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--stop-asks-nothing 'ghostel 'codex)))

(ert-deftest claude-code-ide-live-test-stop-asks-nothing-vterm ()
  "A stop of a Codex instance in vterm asks no question."
  :tags '(:live)
  (claude-code-ide-live-tests--live
    (claude-code-ide-live-tests--stop-asks-nothing 'vterm 'codex)))

;;; Unit tests of the helpers
;;
;; These run in the batch suite, with the mocks of
;; claude-code-ide-tests.el.  They start no CLI and use only temporary
;; folders.

(defmacro claude-code-ide-live-tests--with-temp-folder (var &rest body)
  "Bind VAR to a new temporary folder (a directory name), run BODY, then remove it."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "cci-test-live-" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest claude-code-ide-live-tests-test-read-tools ()
  "Only the read tools are approved for a person; every other tool is not."
  (claude-code-ide-live-tests--with-temp-folder root
    (let* ((process-environment (cons (concat "CLAUDE_CODE_IDE_LIVE_DIR=" root) process-environment))
           (project (file-name-as-directory (expand-file-name "projA" root)))
           (file (expand-file-name "note.txt" project)))
      (make-directory project t)
      (dolist (call `(("Read" ((file_path . ,file)))
                      ("Glob" ((pattern . "*.txt")))
                      ("Grep" ((pattern . "codeword")))
                      ("mcp__claude-sessions__get_session_outline" nil)
                      ("mcp__claude-sessions__get_messages" nil)
                      ("mcp__claude_sessions__get_messages" nil)))
        (should (claude-code-ide-live-tests--read-tool-p (car call) (cadr call) project)))
      (dolist (tool '("Bash" "Write" "Edit" "MultiEdit" "NotebookEdit" "WebFetch"
                      "mcp__emacs-tools__emacs_eval" "mcp__emacs_tools__claude_code_ide_mcp_project_info"
                      "mcp__claude-sessions-evil__x" "Readx" "" nil))
        (should-not (claude-code-ide-live-tests--read-tool-p tool `((file_path . ,file)) project))))))

(ert-deftest claude-code-ide-live-tests-test-read-tool-paths ()
  "A read tool is approved only for a path in a folder of the tests.
These are the live folder, the Claude Code transcript folders of its
projects, and the Codex sessions folder.  A link counts by its target."
  (claude-code-ide-live-tests--with-temp-folder temp
    (let* ((root (file-name-as-directory (expand-file-name "live" temp)))
           (project (file-name-as-directory (expand-file-name "projA" root)))
           (outside (file-name-as-directory (expand-file-name "outside" temp)))
           (claude-dir (expand-file-name "claude-config" temp))
           (codex-dir (expand-file-name "codex-home" temp))
           (process-environment (append (list (concat "CLAUDE_CODE_IDE_LIVE_DIR=" root)
                                              (concat "CLAUDE_CONFIG_DIR=" claude-dir)
                                              (concat "CODEX_HOME=" codex-dir))
                                        process-environment))
           (transcripts (expand-file-name
                         (concat "projects/" (claude-code-ide-live-tests--claude-folder-name project))
                         claude-dir)))
      (make-directory project t)
      (make-directory outside t)
      (make-directory transcripts t)
      (make-symbolic-link outside (expand-file-name "link" project))
      (dolist (call `(("Read" ((file_path . ,(expand-file-name "note.txt" project))))
                      ("Read" ((file_path . "note.txt")))
                      ("Read" ((file_path . ,(expand-file-name ".handover/h-1.md" project))))
                      ("Read" ((file_path . ,(expand-file-name "sessions/2026/11/22/rollout-x.jsonl"
                                                               codex-dir))))
                      ("Read" ((file_path . ,(expand-file-name "abc.jsonl" transcripts))))
                      ("Glob" ((pattern . "**/*.md")))
                      ("Glob" ((pattern . "*.jsonl") (path . ,transcripts)))
                      ("Grep" ((pattern . "MARMOT")))
                      ("Grep" ((pattern . "MARMOT") (path . ,root)))))
        (should (equal (list call t)
                       (list call (and (claude-code-ide-live-tests--read-tool-p
                                        (car call) (cadr call) project)
                                       t)))))
      (dolist (call `(("Read" nil)
                      ("Read" ((file_path . "")))
                      ("Read" ((file_path . "~/.ssh/id_rsa")))
                      ("Read" ((file_path . ,(expand-file-name "secret.txt" outside))))
                      ("Read" ((file_path . "../../outside/secret.txt")))
                      ("Read" ((file_path . ,(expand-file-name "link/secret.txt" project))))
                      ("Read" ((file_path . ,(expand-file-name "projects/-Users-cci-test-other/a.jsonl"
                                                               claude-dir))))
                      ("Read" ((file_path . ,(expand-file-name "config.toml" codex-dir))))
                      ("Glob" ((pattern . "/etc/*")))
                      ("Glob" ((pattern . "../../outside/*")))
                      ("Glob" ((pattern . "*") (path . ,outside)))
                      ("Grep" ((pattern . "x") (path . "/etc")))
                      ("Grep" ((pattern . "x") (path . ,(expand-file-name "link" project))))))
        (should (equal (list call nil)
                       (list call (claude-code-ide-live-tests--read-tool-p
                                   (car call) (cadr call) project)))))
      ;; A relative path needs the folder of the CLI
      (should-not (claude-code-ide-live-tests--read-tool-p "Read" '((file_path . "note.txt")) nil))
      (should-not (claude-code-ide-live-tests--read-tool-p "Grep" '((pattern . "x")) nil)))))

(ert-deftest claude-code-ide-live-tests-test-approval-on-screen ()
  "Only an approval dialog on the current screen counts, not one in the scrollback."
  (let ((claude-code-ide-codex--screen-lines 10))
    (with-temp-buffer
      (insert " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
      (dotimes (i 30) (insert (format "output line %d\n" i)))
      (insert "╭──────╮\n│ >    │\n╰──────╯\n")
      (should-not (claude-code-ide-live-tests--approval-on-screen-p (current-buffer)))
      (insert " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
      (should (claude-code-ide-live-tests--approval-on-screen-p (current-buffer))))))

(ert-deftest claude-code-ide-live-tests-test-document-tool-calls ()
  "The chain check counts only the claude-sessions tools that the document names."
  (should (equal (claude-code-ide-live-tests--document-tool-calls
                  '("list_sessions" "get_session_outline" "get_messages"))
                 '("get_session_outline" "get_messages")))
  (should (equal (claude-code-ide-live-tests--document-tool-calls '("get_messages")) '("get_messages")))
  (should-not (claude-code-ide-live-tests--document-tool-calls '("list_sessions" "export_session")))
  (should-not (claude-code-ide-live-tests--document-tool-calls nil)))

(ert-deftest claude-code-ide-live-tests-test-own-strays ()
  "The stray test ends the strays only when they are exactly its own process."
  (let ((own (list :pid 4242 :command "sleep 900" :reason 'worktree))
        (other (list :pid 4343 :command "node server.js" :reason 'worktree)))
    (should (claude-code-ide-live-tests--own-strays-p (list own) 4242))
    (should-not (claude-code-ide-live-tests--own-strays-p (list own other) 4242))
    (should-not (claude-code-ide-live-tests--own-strays-p (list other own) 4242))
    (should-not (claude-code-ide-live-tests--own-strays-p (list other) 4242))
    (should-not (claude-code-ide-live-tests--own-strays-p nil 4242))))

(ert-deftest claude-code-ide-live-tests-test-cli-processes ()
  "A CLI process counts when any word of its command line is claude or codex.
The npm launcher runs the CLI as node .../bin/claude."
  (let ((lines '((1 . "node /opt/homebrew/bin/claude --session-id cci-test-native")
                 (2 . "/Users/cci-test/.local/bin/claude --resume cci-test-native")
                 (3 . "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex resume cci-test-native")
                 (4 . "codex resume cci-test-native")
                 (5 . "grep cci-test-native")
                 (6 . "tail -f /tmp/claude-cci-test-native.log")
                 (7 . "vim notes-about-claude.txt cci-test-native")
                 (8 . "node /opt/homebrew/bin/claude --session-id cci-test-other")
                 (9 . nil))))
    (cl-letf (((symbol-function 'list-system-processes) (lambda () (mapcar #'car lines)))
              ((symbol-function 'process-attributes)
               (lambda (pid) (when-let* ((args (alist-get pid lines))) (list (cons 'args args))))))
      (should (equal (sort (claude-code-ide-live-tests--cli-processes "cci-test-native") #'<)
                     '(1 2 3 4))))))

(ert-deftest claude-code-ide-live-tests-test-setup-refuses-user-folder ()
  "The setup refuses a folder with files and no owner file before it changes it.
Such a folder is no live folder, for example a folder of the user that
CLAUDE_CODE_IDE_LIVE_DIR names by mistake: its mode stays, and it gets
no lock and no owner file."
  (claude-code-ide-live-tests--with-temp-folder root
    (let ((process-environment (cons (concat "CLAUDE_CODE_IDE_LIVE_DIR=" root) process-environment))
          (user-file (expand-file-name "notes.txt" root))
          (claude-code-ide-live-tests--setup-done nil)
          (claude-code-ide-state-file "/cci-test/unchanged.json")
          (claude-code-ide-cli-environment-unset '("CCI_TEST_ONLY"))
          (changes nil))
      (write-region "the user's notes\n" nil user-file nil 'silent)
      (set-file-modes root #o755)
      (cl-letf (((symbol-function 'claude-code-ide-live-tests--live-p) (lambda () t))
                ((symbol-function 'advice-add) (lambda (&rest args) (push (cons 'advice args) changes)))
                ((symbol-function 'add-hook) (lambda (&rest args) (push (cons 'hook args) changes)))
                ((symbol-function 'claude-code-ide-emacs-tools-setup)
                 (lambda (&rest args) (push (cons 'tools args) changes)))
                ((symbol-function 'claude-code-ide-session-registry-mode)
                 (lambda (&rest args) (push (cons 'registry args) changes))))
        (should-error (claude-code-ide-live-tests-setup) :type 'user-error))
      (should (= (file-modes root) #o755))
      (should (equal (directory-files root nil directory-files-no-dot-files-regexp) '("notes.txt")))
      (should (equal (claude-code-ide-live-tests--file-text user-file) "the user's notes\n"))
      (should-not changes)
      (should-not claude-code-ide-live-tests--setup-done)
      (should (equal claude-code-ide-state-file "/cci-test/unchanged.json"))
      (should (equal claude-code-ide-cli-environment-unset '("CCI_TEST_ONLY"))))))

(ert-deftest claude-code-ide-live-tests-test-approval-tool ()
  "The tool of an approval is that of the newest approval request after the time."
  (let ((claude-code-ide-live-tests--events
         (list (cons 30.0 (list :instance-id "cci-test-a" :event 'approval-request
                                :data '((tool_name . "Bash"))))
               (cons 20.0 (list :instance-id "cci-test-b" :event 'approval-request
                                :data '((tool_name . "Read"))))
               (cons 10.0 (list :instance-id "cci-test-a" :event 'approval-request
                                :data '((tool_name . "Grep")))))))
    (should (equal (claude-code-ide-live-tests--approval-tool "cci-test-a" 0) "Bash"))
    (should (equal (claude-code-ide-live-tests--approval-tool "cci-test-b" 0) "Read"))
    (should-not (claude-code-ide-live-tests--approval-tool "cci-test-a" 40))
    (should-not (claude-code-ide-live-tests--approval-tool "cci-test-c" 0))))

(ert-deftest claude-code-ide-live-tests-test-claude-flags ()
  "The Claude Code flags of the live tests accept no edits by themselves."
  (let ((process-environment (cons "CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS" process-environment)))
    (let ((flags (claude-code-ide-live-tests--claude-flags)))
      (should-not (string-match-p "acceptEdits\\|bypassPermissions\\|dangerously" flags))
      ;; Only the summary folder of the handover may get writes
      (should (string-match-p "Write(\\.handover/\\*\\*)" flags))
      ;; No command runs: Bash is off, and not in the allowed tools
      (should (string-match-p "--disallowedTools Bash" flags))
      (should-not (string-match-p "--allowedTools [^ ]*Bash" flags)))))

(ert-deftest claude-code-ide-live-tests-test-every-live-test-skips ()
  "Each live test skips with a closed gate, before it does anything.
A live test without the gate would start the CLIs in the batch suite.
The gate is closed here also in a live daemon, so that this test never
runs a live body: no setup, no cleanup, no stop, no launch."
  (let ((tests (cl-remove-if-not
                (lambda (test)
                  (string-prefix-p "claude-code-ide-live-test-" (symbol-name (ert-test-name test))))
                (ert-select-tests t t)))
        (calls nil))
    (should (> (length tests) 10))
    (cl-letf (((symbol-function 'claude-code-ide-live-tests--live-p) #'ignore)
              ((symbol-function 'claude-code-ide-live-tests-setup)
               (lambda (&rest _) (push 'setup calls)))
              ((symbol-function 'claude-code-ide-live-tests--cleanup)
               (lambda (&rest _) (push 'cleanup calls)))
              ((symbol-function 'claude-code-ide-live-tests--stop-all)
               (lambda (&rest _) (push 'stop-all calls)))
              ((symbol-function 'claude-code-ide-control-launch)
               (lambda (&rest _) (push 'launch calls) (list :status 'error :reason 'cci-test))))
      (dolist (test tests)
        (let ((result (ert-run-test test)))
          (should (equal (list (ert-test-name test) t)
                         (list (ert-test-name test) (ert-test-skipped-p result)))))))
    (should-not calls)))

(ert-deftest claude-code-ide-live-tests-test-setup-needs-gate ()
  "The setup refuses to run outside a live test daemon, before it changes anything."
  (let ((claude-code-ide-live-tests--setup-done nil)
        (claude-code-ide-state-file "/cci-test/unchanged.json")
        (claude-code-ide-cli-extra-flags "cci-test-flags")
        (claude-code-ide-cli-environment-unset '("CCI_TEST_ONLY"))
        (claude-code-ide-enable-mcp-server nil)
        (changes nil))
    (cl-letf (((symbol-function 'claude-code-ide-live-tests--live-p) #'ignore)
              ((symbol-function 'advice-add) (lambda (&rest args) (push (cons 'advice args) changes)))
              ((symbol-function 'add-hook) (lambda (&rest args) (push (cons 'hook args) changes)))
              ((symbol-function 'make-directory) (lambda (&rest args) (push (cons 'mkdir args) changes)))
              ((symbol-function 'claude-code-ide-live-tests--claim-root)
               (lambda (&rest args) (push (cons 'claim args) changes)))
              ((symbol-function 'claude-code-ide-emacs-tools-setup)
               (lambda (&rest args) (push (cons 'tools args) changes)))
              ((symbol-function 'claude-code-ide-session-registry-mode)
               (lambda (&rest args) (push (cons 'registry args) changes))))
      (should-error (claude-code-ide-live-tests-setup) :type 'user-error))
    (should-not changes)
    (should-not claude-code-ide-live-tests--setup-done)
    (should (equal claude-code-ide-state-file "/cci-test/unchanged.json"))
    (should (equal claude-code-ide-cli-extra-flags "cci-test-flags"))
    (should (equal claude-code-ide-cli-environment-unset '("CCI_TEST_ONLY")))
    (should-not claude-code-ide-enable-mcp-server)))

(ert-deftest claude-code-ide-live-tests-test-codeword-files ()
  "A test creates only new codeword files, and the cleanup deletes only those."
  (claude-code-ide-live-tests--with-temp-folder root
    (let* ((process-environment (cons (concat "CLAUDE_CODE_IDE_LIVE_DIR=" root) process-environment))
           (project (file-name-as-directory (expand-file-name "projA" root)))
           (user-file (expand-file-name "note-user.txt" project))
           (outside (file-name-as-directory (expand-file-name "outside" root)))
           (outside-file (expand-file-name "note-outside.txt" outside))
           (claude-code-ide-live-tests--created-files nil))
      (make-directory project t)
      (make-directory outside t)
      (write-region "the user's note\n" nil user-file nil 'silent)
      (write-region "the user's other note\n" nil outside-file nil 'silent)
      ;; A child folder that links elsewhere
      (make-symbolic-link outside (expand-file-name "linked" root))
      ;; A file that exists is never overwritten
      (should-error (claude-code-ide-live-tests--write-secret project "note-user.txt" "CCI-TEST-1"))
      (should (equal (claude-code-ide-live-tests--file-text user-file) "the user's note\n"))
      ;; A new file is written and recorded
      (let ((file (claude-code-ide-live-tests--write-secret project "note-1.txt" "CCI-TEST-2")))
        (should (file-exists-p file))
        (should (member file claude-code-ide-live-tests--created-files))
        (claude-code-ide-live-tests--cleanup)
        (should-not (file-exists-p file)))
      ;; The files that no test made stay
      (should (file-exists-p user-file))
      (should (file-exists-p outside-file))
      (should-not claude-code-ide-live-tests--created-files))))

(defun claude-code-ide-live-tests--test-lock (root holder)
  "Make the claim lock of ROOT, held by HOLDER (a text \"PID START\"), or by nobody.
The lock is old: its time is a minute ago.  Return the lock folder."
  (let ((lock (expand-file-name "owner.lock" root)))
    (make-directory lock)
    (when holder
      (write-region holder nil (expand-file-name "holder" lock) nil 'silent))
    (set-file-times lock (time-subtract nil 60))
    lock))

(ert-deftest claude-code-ide-live-tests-test-claim-lock ()
  "A claim lock that exists stays: the claim waits its time, then gives up.
No claim ever removes the lock of another: not because of its age, not
because its holder seems gone.  The error names the lock, its holder,
and the command to remove it by hand."
  (claude-code-ide-live-tests--with-temp-folder root
    (let ((owner (expand-file-name "owner" root))
          (claude-code-ide-live-tests--claim-wait 0.5)
          (other (make-process :name "cci-test-holder" :command '("sleep" "30")
                               :connection-type 'pipe :noquery t)))
      (unwind-protect
          (dolist (holder (list (format "%d %s" (process-id other)
                                        (claude-code-ide-live-tests--start-time (process-id other)))
                                nil
                                "999999999 1.0"))
            (let ((lock (claude-code-ide-live-tests--test-lock root holder))
                  (start (float-time))
                  (err nil))
              ;; The deadline holds: no hang, whatever the holder is
              (with-timeout (5 (ert-fail "the claim does not end"))
                (setq err (should-error (claude-code-ide-live-tests--claim-root root)
                                        :type 'user-error)))
              (should (< (- (float-time) start) 3))
              (should (file-directory-p lock))
              (should (equal (and holder (claude-code-ide-live-tests--file-text
                                          (expand-file-name "holder" lock)))
                             holder))
              (should-not (file-exists-p owner))
              (let ((text (error-message-string err)))
                (should (string-search lock text))
                (should (string-search (concat "rm -r " (shell-quote-argument lock)) text))
                (when holder (should (string-search holder text))))
              (delete-directory lock t)))
        (delete-process other)))))

(ert-deftest claude-code-ide-live-tests-test-claim-lock-holder ()
  "The claim writes its holder file, and removes its lock at the end."
  (claude-code-ide-live-tests--with-temp-folder root
    (let* ((lock (expand-file-name "owner.lock" root))
           (holder (expand-file-name "holder" lock))
           (seen nil))
      ;; While the claim holds the lock, the holder file names this Emacs
      (cl-letf (((symbol-function 'claude-code-ide-live-tests--claim-root-1)
                 (lambda (_root)
                   (setq seen (claude-code-ide-live-tests--file-text holder)))))
        (claude-code-ide-live-tests--claim-root root))
      (should (string-prefix-p (format "%d" (emacs-pid)) seen))
      (should-not (file-exists-p lock))
      ;; Also after an error in the claim
      (cl-letf (((symbol-function 'claude-code-ide-live-tests--claim-root-1)
                 (lambda (_root) (user-error "cci-test"))))
        (should-error (claude-code-ide-live-tests--claim-root root) :type 'user-error))
      (should-not (file-exists-p lock)))))

(ert-deftest claude-code-ide-live-tests-test-log-only-live ()
  "Outside a live run, the log writes no file; the line goes only to *Messages*.
A unit test of a helper that logs must not write to the live folder of
the repository, which also need not exist."
  (let* ((root (make-temp-file "cci-test-live-log-" t))
         (process-environment (cons (concat "CLAUDE_CODE_IDE_LIVE_DIR=" root)
                                    process-environment)))
    (unwind-protect
        ;; Closed gate, also when this test runs in a live daemon
        (cl-letf (((symbol-function 'claude-code-ide-live-tests--live-p) #'ignore))
          (claude-code-ide-live-tests--log "cci-test %s" "line")
          (should-not (file-exists-p (expand-file-name "log.txt" root)))
          ;; A live folder that does not exist gives no error either
          (let ((process-environment (cons (concat "CLAUDE_CODE_IDE_LIVE_DIR="
                                                   (expand-file-name "missing" root))
                                           process-environment)))
            (claude-code-ide-live-tests--log "cci-test %s" "line")))
      (delete-directory root t))))

(ert-deftest claude-code-ide-live-tests-test-approval-names-tool ()
  "The person in a test allows only the tool that the test expects."
  (let ((claude-code-ide-live-tests--events
         (list (cons 20.0 (list :instance-id "cci-test-a" :event 'approval-request
                                :data '((tool_name . "mcp__emacs_tools__emacs_eval"))))
               (cons 10.0 (list :instance-id "cci-test-b" :event 'approval-request
                                :data '((tool_name . "mcp__emacs_tools__claude_code_ide_mcp_project_info")))))))
    (should (claude-code-ide-live-tests--expect-approval
             "cci-test-b" "mcp__emacs_tools__claude_code_ide_mcp_project_info" 0 0.2))
    (should-error (claude-code-ide-live-tests--expect-approval
                   "cci-test-a" "mcp__emacs_tools__claude_code_ide_mcp_project_info" 0 0.2)
                  :type 'ert-test-failed)
    ;; No request at all fails too
    (should-error (claude-code-ide-live-tests--expect-approval
                   "cci-test-c" "mcp__emacs_tools__claude_code_ide_mcp_project_info" 0 0.2)
                  :type 'ert-test-failed)))

(ert-deftest claude-code-ide-live-tests-test-session-tool-calls ()
  "Only real calls of the claude-sessions tools count, by the tool fields of the record."
  (claude-code-ide-live-tests--with-temp-folder root
    (let ((rollout (expand-file-name "rollout.jsonl" root))
          (lines
           (list
            ;; An exec call that only prints the name
            '((type . "response_item")
              (payload . ((type . "custom_tool_call") (name . "exec")
                          (input . "text(\"mcp__claude_sessions__get_messages\")"))))
            ;; Its text in a message
            '((type . "response_item")
              (payload . ((type . "message")
                          (content . [((type . "output_text")
                                       (text . "I call mcp__claude_sessions__get_session_outline"))]))))
            ;; A call of another server
            '((type . "event_msg")
              (payload . ((type . "item_completed")
                          (item . ((type . "McpToolCall") (server . "emacs-tools")
                                   (tool . "get_messages") (status . "completed"))))))
            ;; A failed call
            '((type . "event_msg")
              (payload . ((type . "item_completed")
                          (item . ((type . "McpToolCall") (server . "claude-sessions")
                                   (tool . "get_session_outline") (status . "failed"))))))
            ;; Real calls: an MCP item of code mode, and a direct function call
            '((type . "event_msg")
              (payload . ((type . "item_completed")
                          (item . ((type . "McpToolCall") (server . "claude-sessions")
                                   (tool . "get_messages") (status . "completed"))))))
            '((type . "response_item")
              (payload . ((type . "function_call")
                          (name . "mcp__claude_sessions__get_session_outline")))))))
      (with-temp-file rollout
        (dolist (line (butlast lines 2))
          (insert (json-encode line) "\n")))
      (should-not (claude-code-ide-live-tests--session-tool-calls rollout))
      (with-temp-file rollout
        (dolist (line lines)
          (insert (json-encode line) "\n"))
        (insert "not json\n"))
      (should (equal (claude-code-ide-live-tests--session-tool-calls rollout)
                     '("get_messages" "get_session_outline"))))))

(ert-deftest claude-code-ide-live-tests-test-recovery-keeps-target ()
  "The recovery test does not stop the recovered target before it checks it."
  (let ((calls nil))
    (cl-letf (((symbol-function 'claude-code-ide-live-tests--live-p) (lambda () t))
              ((symbol-function 'claude-code-ide-live-tests-setup) #'ignore)
              ((symbol-function 'claude-code-ide-live-tests--stop-all)
               (lambda (&rest _) (push 'stop-all calls)))
              ((symbol-function 'claude-code-ide-live-tests--cleanup)
               (lambda (&rest _) (push 'cleanup calls)))
              ;; No recovery state: the body skips at once
              ((symbol-function 'claude-code-ide-live-tests--recovery-file)
               (lambda () "/cci-test/no-such-recovery.eld")))
      (let ((result (ert-run-test (ert-get-test 'claude-code-ide-live-test-recovery-2-after-kill))))
        (should (ert-test-skipped-p result))))
    ;; Only the cleanup after the body, no stop before it
    (should (equal calls '(cleanup)))))

(ert-deftest claude-code-ide-live-tests-test-hide-buffer ()
  "A hidden terminal buffer shows in no window of any frame.
The package shows a terminal in a window that is dedicated to it; such
a window goes, or, as the only window of its frame, shows another
buffer."
  (let ((buffer (generate-new-buffer " *cci-test-terminal*")))
    (unwind-protect
        ;; The window layout of the Emacs that runs the test comes back
        (save-window-excursion
          (delete-other-windows)
          (let ((window (selected-window)))
            (set-window-dedicated-p window nil)
            ;; A plain window
            (set-window-buffer window buffer)
            (should (get-buffer-window-list buffer nil t))
            (claude-code-ide-live-tests--hide-buffer buffer)
            (should-not (get-buffer-window-list buffer nil t))
            ;; A dedicated window next to another one
            (let ((side (split-window window)))
              (set-window-buffer side buffer)
              (set-window-dedicated-p side t)
              (claude-code-ide-live-tests--hide-buffer buffer)
              (should-not (get-buffer-window-list buffer nil t))
              (when (window-live-p side) (delete-window side)))
            ;; A dedicated window that is the only one of its frame
            (set-window-buffer window buffer)
            (set-window-dedicated-p window t)
            (claude-code-ide-live-tests--hide-buffer buffer)
            (should-not (get-buffer-window-list buffer nil t))
            (should (buffer-live-p buffer))
            (set-window-dedicated-p window nil)))
      (kill-buffer buffer))))

(ert-deftest claude-code-ide-live-tests-test-gate ()
  "The live tests run only in a daemon, outside batch mode, without the mocks."
  (let ((process-environment (cons "CLAUDE_CODE_IDE_LIVE_TESTS=1" process-environment))
        (real-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &rest args)
                 (and (not (eq feature 'claude-code-ide-tests))
                      (apply real-featurep feature args)))))
      (let ((noninteractive nil)
            (init-file-user nil))
        ;; emacs -Q: no init file
        (dolist (name (list "cci-test" t))
          (cl-letf (((symbol-function 'daemonp) (lambda () name)))
            (should (claude-code-ide-live-tests--live-p))))
        ;; An Emacs with a frame of its own is not the test daemon
        (cl-letf (((symbol-function 'daemonp) (lambda () nil)))
          (should-not (claude-code-ide-live-tests--live-p)))
        ;; A daemon that loaded an init file is a person's daemon, unless
        ;; its name starts with cci-live
        (dolist (user (list "" "cci-test-user"))
          (let ((init-file-user user))
            (dolist (name (list t "server" "work" "my-cci-live"))
              (cl-letf (((symbol-function 'daemonp) (lambda () name)))
                (should-not (claude-code-ide-live-tests--live-p))))
            (dolist (name (list "cci-live" "cci-live-2"))
              (cl-letf (((symbol-function 'daemonp) (lambda () name)))
                (should (claude-code-ide-live-tests--live-p)))))))
      (let ((noninteractive t))
        (cl-letf (((symbol-function 'daemonp) (lambda () "cci-test")))
          (should-not (claude-code-ide-live-tests--live-p)))))
    ;; With the mocks, never
    (should-not (claude-code-ide-live-tests--live-p))))

(ert-deftest claude-code-ide-live-tests-test-environment ()
  "The Claude Code CLI of the live tests gets no key and no marker of a parent CLI.
The package sets CLAUDE_CODE_SSE_PORT itself, so that one stays."
  (let ((claude-code-ide-cli-environment-unset '("CCI_TEST_USER_VAR"))
        (claude-code-ide-no-flicker nil))
    (setq claude-code-ide-cli-environment-unset (claude-code-ide-live-tests--environment-unset))
    (let ((env (claude-code-ide--cli-environment 4242)))
      (dolist (name '("ANTHROPIC_API_KEY" "OPENAI_API_KEY" "CLAUDECODE"
                      "CLAUDE_CODE_CHILD_SESSION" "CLAUDE_CODE_ENTRYPOINT" "CCI_TEST_USER_VAR"))
        (should (member name env)))
      ;; The first entry of a name wins: the port of this Emacs
      (should (equal (seq-find (lambda (entry) (string-prefix-p "CLAUDE_CODE_SSE_PORT" entry)) env)
                     "CLAUDE_CODE_SSE_PORT=4242")))
    ;; A second call adds nothing twice
    (should (= (length claude-code-ide-cli-environment-unset)
               (length (delete-dups (claude-code-ide-live-tests--environment-unset)))))))

(ert-deftest claude-code-ide-live-tests-test-trust-files ()
  "The trust checks read the config files of the CLIs, by the true folder name."
  (claude-code-ide-live-tests--with-temp-folder root
    (let* ((project (file-name-as-directory (expand-file-name "projA" root)))
           (true (directory-file-name (file-truename project)))
           (claude-dir (expand-file-name "claude-config" root))
           (codex-dir (expand-file-name "codex-home" root))
           (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" claude-dir)
                                              (concat "CODEX_HOME=" codex-dir))
                                        process-environment)))
      (make-directory project t)
      (make-directory claude-dir t)
      (make-directory codex-dir t)
      (should-not (claude-code-ide-live-tests--claude-trusts-folder-p project))
      (should-not (claude-code-ide-live-tests--codex-trusts-folder-p project))
      (with-temp-file (expand-file-name ".claude.json" claude-dir)
        (insert (json-encode `((projects . ((,(intern true) . ((hasTrustDialogAccepted . t)))))))))
      (with-temp-file (expand-file-name "config.toml" codex-dir)
        (insert (format "[projects.%S]\ntrust_level = \"trusted\"\n" true)))
      ;; The temporary folder of macOS is a link (/var -> /private/var)
      (should (claude-code-ide-live-tests--claude-trusts-folder-p project))
      (should (claude-code-ide-live-tests--codex-trusts-folder-p project)))))

(ert-deftest claude-code-ide-live-tests-test-settled-trust-screen ()
  "The composer counts as trusted only when no trust dialog follows it.
Codex 0.164 can draw its composer first and the folder trust dialog a
moment later: a live run took that first screen for trusted, and the
handover target then waited on the dialog."
  (let* ((texts nil)
         (read (lambda () (or (pop texts) ""))))
    ;; The composer, then the dialog: the dialog wins
    (setq texts (list "› Ask Codex to do anything"
                      "Trust this folder? › 1. Trust and continue  Your trust decision will be saved"))
    (should (eq (claude-code-ide-live-tests--settled-trust-screen read 0 5) 'dialog))
    ;; The composer twice: trusted
    (setq texts (list "› Ask Codex to do anything" "› Ask Codex to do anything"))
    (should (eq (claude-code-ide-live-tests--settled-trust-screen read 0 5) 'ready))
    ;; The dialog at once
    (setq texts (list "Trust and continue"))
    (should (eq (claude-code-ide-live-tests--settled-trust-screen read 0 5) 'dialog))
    ;; Nothing in time
    (setq texts nil)
    (should-not (claude-code-ide-live-tests--settled-trust-screen read 0 0.5))))

(ert-deftest claude-code-ide-live-tests-test-trust-screens ()
  "A trust check sees the dialog, or the CLI at its prompt, which counts as trusted."
  (should (eq (claude-code-ide-live-tests--claude-trust-screen
               " Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n" nil)
              'dialog))
  ;; Hooks run only after the trust, so a session start means trusted
  (should (eq (claude-code-ide-live-tests--claude-trust-screen "╭───╮\n│ > \n" t) 'ready))
  (should-not (claude-code-ide-live-tests--claude-trust-screen "Loading" nil))
  (should (eq (claude-code-ide-live-tests--codex-trust-screen
               "Do you trust the contents of this directory?\n› 1. Trust and continue\n  2. Quit\n Your trust decision will be saved")
              'dialog))
  (should (eq (claude-code-ide-live-tests--codex-trust-screen
               "  >_ OpenAI Codex (v0.164.0)\n› Ask Codex to do anything\n")
              'ready))
  (should-not (claude-code-ide-live-tests--codex-trust-screen "")))

(ert-deftest claude-code-ide-live-tests-test-delivery-time ()
  "The turn of a prompt is the first turn end after the delivery of that prompt."
  (let ((claude-code-ide-live-tests--events
         ;; Newest first
         (list (cons 40.0 (list :instance-id "cci-test-a" :event 'turn-end
                                :data '((last_assistant_message . "answer"))))
               (cons 30.0 (list :instance-id "cci-test-a" :event 'prompt-submit
                                :data '((prompt . "cci-test-L-q: the question"))))
               (cons 20.0 (list :instance-id "cci-test-a" :event 'turn-end
                                :data '((last_assistant_message . "first turn"))))
               (cons 10.0 (list :instance-id "cci-test-a" :event 'prompt-submit
                                :data '((prompt . "cci-test-L first task")))))))
    (should (= (claude-code-ide-live-tests--delivery-time "cci-test-a" "cci-test-L-q: the question" 0)
               30.0))
    (should-not (claude-code-ide-live-tests--delivery-time "cci-test-a" "cci-test-L-q: the question" 35))
    (should-not (claude-code-ide-live-tests--delivery-time "cci-test-a" "another text" 0))
    ;; The first turn end does not count for the question
    (should (equal (claude-code-ide-live-tests--reply
                    (claude-code-ide-live-tests--event "cci-test-a" 'turn-end 30.0))
                   "answer"))))

(ert-deftest claude-code-ide-live-tests-test-one-daemon-per-folder ()
  "A live folder belongs to one live Emacs at a time."
  (claude-code-ide-live-tests--with-temp-folder root
    (let ((owner (expand-file-name "owner" root)))
      ;; A new folder: this Emacs takes it, and takes it again
      (claude-code-ide-live-tests--claim-root root)
      (should (file-exists-p owner))
      (claude-code-ide-live-tests--claim-root root)
      ;; An Emacs that ended: its claim is old
      (with-temp-file owner (insert "999999999 0\n"))
      (claude-code-ide-live-tests--claim-root root)
      (let* ((other (make-process :name "cci-test-owner" :command '("sleep" "30")
                                  :connection-type 'pipe :noquery t))
             (pid (process-id other))
             (start (claude-code-ide-live-tests--start-time pid)))
        (unwind-protect
            (progn
              ;; A process ID that now names another process (a known
              ;; other start time) is an old claim too
              (with-temp-file owner (insert (format "%d 1.0\n" pid)))
              (claude-code-ide-live-tests--claim-root root)
              ;; A live process with the start time of the claim holds the folder
              (with-temp-file owner (insert (format "%d %s\n" pid start)))
              (should-error (claude-code-ide-live-tests--claim-root root) :type 'user-error)
              ;; An unknown start time of the owner is the safe side: it
              ;; still runs, also as "nil", never as 0
              (dolist (text (list (format "%d\n" pid) (format "%d nil\n" pid)))
                (with-temp-file owner (insert text))
                (should-error (claude-code-ide-live-tests--claim-root root) :type 'user-error))
              ;; So is a start time that cannot be read now
              (with-temp-file owner (insert (format "%d %s\n" pid start)))
              (let ((real (symbol-function 'claude-code-ide-live-tests--start-time)))
                (cl-letf (((symbol-function 'claude-code-ide-live-tests--start-time)
                           (lambda (p) (unless (eql p pid) (funcall real p)))))
                  (should-error (claude-code-ide-live-tests--claim-root root) :type 'user-error))))
          (delete-process other)))
      ;; A dead owner PID is accepted, also without a start time
      (with-temp-file owner (insert "999999999\n"))
      (claude-code-ide-live-tests--claim-root root)
      ;; This Emacs writes its PID only when it cannot read its own start time
      (let ((real (symbol-function 'claude-code-ide-live-tests--start-time)))
        (cl-letf (((symbol-function 'claude-code-ide-live-tests--start-time)
                   (lambda (p) (unless (eql p (emacs-pid)) (funcall real p)))))
          (claude-code-ide-live-tests--claim-root root)))
      (should (equal (claude-code-ide-live-tests--file-text owner) (format "%d\n" (emacs-pid)))))))

(ert-deftest claude-code-ide-live-tests-test-leftovers ()
  "The cleanup list names the trust entries and transcript folders of the live folder."
  (claude-code-ide-live-tests--with-temp-folder root
    (let* ((live (file-name-as-directory (expand-file-name "live" root)))
           (project (directory-file-name (file-truename (expand-file-name "projA" live))))
           (other "/Users/cci-test/elsewhere")
           (claude-dir (expand-file-name "claude-config" root))
           (codex-dir (expand-file-name "codex-home" root))
           (transcripts (expand-file-name
                         (concat "projects/" (replace-regexp-in-string "[^A-Za-z0-9]" "-" project))
                         claude-dir))
           (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" claude-dir)
                                              (concat "CODEX_HOME=" codex-dir))
                                        process-environment)))
      (make-directory (expand-file-name "projA" live) t)
      (make-directory transcripts t)
      (make-directory codex-dir t)
      (with-temp-file (expand-file-name ".claude.json" claude-dir)
        (insert (json-encode `((projects . ((,(intern project) . ((hasTrustDialogAccepted . t)))
                                            (,(intern other) . ((hasTrustDialogAccepted . t)))))))))
      (with-temp-file (expand-file-name "config.toml" codex-dir)
        (insert (format "[projects.%S]\ntrust_level = \"trusted\"\n\n[projects.%S]\ntrust_level = \"trusted\"\n"
                        project other)))
      (let ((left (claude-code-ide-live-tests-leftovers live)))
        (should (equal (plist-get left :codex-trust) (list project)))
        (should (equal (plist-get left :claude-trust) (list project)))
        (should (equal (plist-get left :claude-transcripts) (list (file-name-as-directory transcripts))))))))

;;; Running the tests in the daemon

(defun claude-code-ide-live-tests-run (selector output)
  "Run the live tests of SELECTOR from a timer, and write the results to OUTPUT.
SELECTOR is an ERT selector, such as a regexp.  The call returns at
once, so that `emacsclient' does not wait.  OUTPUT gets one line for
each test (passed, failed, skipped) with the condition of a failure,
and the line \"done\" at the end."
  (run-at-time
   0 nil
   (lambda ()
     (let ((lines nil))
       (condition-case err
           (let ((stats (ert-run-tests
                         selector
                         (lambda (event-type &rest args)
                           (when (eq event-type 'test-ended)
                             (let* ((test (nth 1 args))
                                    (result (nth 2 args))
                                    (line (format "%s %s%s"
                                                  (cond ((ert-test-passed-p result) "PASSED")
                                                        ((ert-test-skipped-p result) "SKIPPED")
                                                        (t "FAILED"))
                                                  (ert-test-name test)
                                                  (if (ert-test-result-with-condition-p result)
                                                      (format " %S" (ert-test-result-with-condition-condition result))
                                                    ""))))
                               (claude-code-ide-live-tests--log "%s" line)
                               (push line lines)
                               (write-region (concat line "\n") nil output t 'silent)))))))
             (ignore stats))
         (error (write-region (format "ERROR %S\n" err) nil output t 'silent)))
       (write-region "done\n" nil output t 'silent))))
  nil)

(provide 'claude-code-ide-live-tests)

;;; claude-code-ide-live-tests.el ends here
