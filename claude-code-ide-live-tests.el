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
They need CLAUDE_CODE_IDE_LIVE_TESTS=1, an Emacs that is not in batch
mode (the CLIs need real terminals), and the real packages, not the
mocks of claude-code-ide-tests.el."
  (and (equal (getenv "CLAUDE_CODE_IDE_LIVE_TESTS") "1")
       (not noninteractive)
       (not (featurep 'claude-code-ide-tests))))

(defmacro claude-code-ide-live-tests--skip-unless-live ()
  "Skip the current test unless the live tests may run."
  '(progn
     (skip-unless (claude-code-ide-live-tests--live-p))
     (claude-code-ide-live-tests-setup)))

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
  "Append a line made of FORMAT-STRING and ARGS to log.txt of the live folder."
  (let ((line (concat (format-time-string "%FT%T ") (apply #'format format-string args) "\n")))
    (write-region line nil (claude-code-ide-live-tests--path "log.txt") t 'silent)
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
CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS replaces them."
  (or (getenv "CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS")
      (format "--model sonnet --permission-mode acceptEdits --add-dir %s"
              (shell-quote-argument
               (expand-file-name "sessions" (claude-code-ide-handover--codex-home))))))

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

;;;###autoload
(defun claude-code-ide-live-tests-setup ()
  "Point the package at the live folder and turn on the session registry.
It runs once in each Emacs; a second call does nothing."
  (unless claude-code-ide-live-tests--setup-done
    (let ((root (claude-code-ide-live-tests--root)))
      (make-directory root t)
      (set-file-modes root #o700)
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

(defun claude-code-ide-live-tests--write-secret (directory name codeword)
  "Write CODEWORD to the file NAME in DIRECTORY, and return the file."
  (let ((file (expand-file-name name directory)))
    (write-region (concat "The codeword is " codeword ".\n") nil file nil 'silent)
    file))

(defun claude-code-ide-live-tests--launch (directory provider prompt)
  "Start PROVIDER in DIRECTORY with the first PROMPT, and return the instance ID."
  (let ((result (claude-code-ide-control-launch :directory directory :provider provider
                                                :prompt prompt)))
    (claude-code-ide-live-tests--log "launch %s in %s: %S" provider directory result)
    (should (eq (plist-get result :status) 'ok))
    (plist-get result :instance-id)))

(defun claude-code-ide-live-tests--stop (instance-id)
  "Stop INSTANCE-ID with the control operation, and return its result.
The terminal of eat asks whether to kill its running process, and in a
daemon that question blocks Emacs (see the tests stop-asks-nothing).
So this stop of the tests binds `kill-buffer-query-functions' to nil."
  (let ((kill-buffer-query-functions nil))
    (claude-code-ide-control-stop instance-id)))

(defun claude-code-ide-live-tests--stop-all ()
  "Stop every instance of this Emacs, and wait until their terminals end."
  (dolist (instance (claude-code-ide-instances))
    (when (claude-code-ide-instance-live-p instance)
      (claude-code-ide-live-tests--stop (claude-code-ide-instance-id instance))))
  (claude-code-ide-live-tests--wait
   (lambda () (not (cl-some #'claude-code-ide-instance-live-p (claude-code-ide-instances))))
   30 "the end of all instances"))

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

(defun claude-code-ide-live-tests--codex-trusts-folder-p (directory)
  "Return non-nil when the Codex config has a trust entry for DIRECTORY."
  (string-search (format "[projects.%S]" (directory-file-name (expand-file-name directory)))
                 (claude-code-ide-live-tests--codex-config-text)))

(defun claude-code-ide-live-tests--ensure-codex-folder-trust (directory)
  "Make sure that Codex trusts DIRECTORY, or skip the test.
Codex asks one time for each new repository root, and it saves the
answer in its config file; no flag avoids the question.  With
CLAUDE_CODE_IDE_LIVE_CODEX_TRUST=1 the test answers \"Trust and
continue\" as a person, which writes [projects.\"DIRECTORY\"] to the
Codex config.  Without the variable, a folder without trust skips the
test."
  (unless (claude-code-ide-live-tests--codex-trusts-folder-p directory)
    (unless (claude-code-ide-live-tests--may-trust-p)
      (ert-skip (format "Codex does not trust %s; see docs/live-tests.md" directory)))
    (let ((id (claude-code-ide-live-tests--launch directory 'codex nil)))
      (should (claude-code-ide-live-tests--wait
               (lambda () (eq (claude-code-ide-codex-screen-dialog
                               (claude-code-ide-live-tests--buffer id))
                              'folder-trust))
               60 "the folder trust dialog"))
      (claude-code-ide-live-tests--send-key id 'return)
      (should (claude-code-ide-live-tests--wait
               (lambda () (claude-code-ide-live-tests--codex-trusts-folder-p directory))
               30 "the trust entry"))
      (claude-code-ide-live-tests--log "Codex trusts %s now (written by Codex)" directory)
      (claude-code-ide-live-tests--stop id)
      (claude-code-ide-live-tests--wait
       (lambda () (not (claude-code-ide-live-tests--running-p id)))
       30 "the end of the trust instance"))))

;;; Claude Code folder trust

(defun claude-code-ide-live-tests--may-trust-p ()
  "Return non-nil when the tests may answer the folder trust dialogs of the CLIs."
  (equal (getenv "CLAUDE_CODE_IDE_LIVE_TRUST") "1"))

(defun claude-code-ide-live-tests--claude-trusts-folder-p (directory)
  "Return non-nil when the Claude Code config trusts DIRECTORY itself."
  (let ((file (expand-file-name ".claude.json" "~")))
    (when (file-readable-p file)
      (let* ((config (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8))
                         (insert-file-contents file))
                       (json-parse-buffer :object-type 'hash-table :false-object nil)))
             (projects (gethash "projects" config))
             (entry (and (hash-table-p projects)
                         (gethash (directory-file-name (expand-file-name directory)) projects))))
        (and (hash-table-p entry) (gethash "hasTrustDialogAccepted" entry))))))

(defun claude-code-ide-live-tests--ensure-claude-folder-trust (directory)
  "Make sure that Claude Code trusts DIRECTORY, or skip the test.
A new folder gets the question \"Is this a project you created or one
you trust?\", whose default is \"No, exit\".  With
CLAUDE_CODE_IDE_LIVE_TRUST=1 the test chooses \"Yes, I trust this
folder\" as a person, which writes the trust of DIRECTORY to
~/.claude.json.  Without the variable, the test skips."
  (unless (claude-code-ide-live-tests--claude-trusts-folder-p directory)
    (unless (claude-code-ide-live-tests--may-trust-p)
      (ert-skip (format "Claude Code does not trust %s; see docs/live-tests.md" directory)))
    (let ((id (claude-code-ide-live-tests--launch directory 'claude nil)))
      (should (claude-code-ide-live-tests--wait
               (lambda () (string-search "Yes, I trust this folder"
                                         (claude-code-ide-live-tests--buffer-text id)))
               60 "the Claude Code folder trust dialog"))
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
      (claude-code-ide-live-tests--log "Claude Code trusts %s now (written by Claude Code)" directory)
      (claude-code-ide-live-tests--stop id)
      (claude-code-ide-live-tests--wait
       (lambda () (not (claude-code-ide-live-tests--running-p id)))
       30 "the end of the trust instance"))))

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
      (let ((start (float-time)))
        (should (eq (plist-get (claude-code-ide-control-submit instance-id prompt :queue t) :result)
                    'queued))
        (should (claude-code-ide-live-tests--wait-turn
                 instance-id start claude-code-ide-live-tests--turn-limit)))
      (delete-file (expand-file-name file-name directory)))))

(defun claude-code-ide-live-tests--first-turn (instance-id directory file-name codeword)
  "Wait for the first turn of INSTANCE-ID, then delete FILE-NAME.
That turn reads the file.
The file with CODEWORD in DIRECTORY must exist before the start."
  (ignore codeword)
  (should (claude-code-ide-live-tests--wait-turn instance-id 0 claude-code-ide-live-tests--turn-limit))
  (delete-file (expand-file-name file-name directory)))

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

(defun claude-code-ide-live-tests--approve-while (instance-id predicate seconds)
  "Wait until PREDICATE is non-nil, and approve the tools of INSTANCE-ID.
The test answers \"1. Yes\" as a person, and logs the screen of each
approval.  Use it only for a question that needs reads alone.  Return
the value of PREDICATE, or nil after SECONDS."
  (claude-code-ide-live-tests--wait
   (lambda ()
     (or (funcall predicate)
         (progn
           (when (equal (claude-code-ide-live-tests--state instance-id) '(waiting-for-user approval))
             (let ((text (claude-code-ide-live-tests--buffer-text instance-id)))
               (when (string-match-p "Do you want to proceed" text)
                 (claude-code-ide-live-tests--log
                  "%s: the test approves, as a person: %s" instance-id
                  (replace-regexp-in-string
                   "[ \t\n│]+" " " (substring text (max 0 (- (length text) 600)))))
                 (claude-code-ide-live-tests--send-key instance-id "1")
                 (accept-process-output nil 3))))
           nil)))
   seconds (format "a turn end of %s with approvals" instance-id)))

(defun claude-code-ide-live-tests--ask (instance-id question)
  "Submit QUESTION to INSTANCE-ID, and return the reply of its turn.
A question needs reads only, so the test approves the tool calls of
the turn as a person; see `claude-code-ide-live-tests--approve-while'."
  (let ((start (float-time)))
    ;; The target may still run its first turn: the inbox sends when idle
    (should (memq (plist-get (claude-code-ide-control-submit instance-id question :queue t) :result)
                  '(queued delivered)))
    (claude-code-ide-live-tests--wait
     (lambda () (claude-code-ide-live-tests--event instance-id 'prompt-submit start))
     claude-code-ide-live-tests--turn-limit "the delivery of the question")
    (claude-code-ide-live-tests--approve-while
     instance-id (lambda () (claude-code-ide-live-tests--event instance-id 'turn-end start))
     claude-code-ide-live-tests--turn-limit)
    (claude-code-ide-live-tests--wait-turn instance-id start claude-code-ide-live-tests--turn-limit)))

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

(defun claude-code-ide-live-tests--session-tool-calls (rollout)
  "Return the names of the claude-sessions tools that the Codex ROLLOUT calls.
A tool call is a record of the type function_call, custom_tool_call or
mcp_tool_call; Codex in code mode calls MCP tools from its exec tool,
as tools.mcp__claude_sessions__NAME."
  (let ((names nil))
    (dolist (line (split-string (claude-code-ide-live-tests--file-text rollout) "\n" t))
      (when (string-match-p "\"type\":\"\\(?:function_call\\|custom_tool_call\\|mcp_tool_call[a-z_]*\\)\"" line)
        (let ((start 0))
          (while (string-match "mcp__claude_sessions__\\([a-z_]+\\)" line start)
            (cl-pushnew (match-string 1 line) names :test #'equal)
            (setq start (match-end 0))))
        (when (string-match-p "\"server\":\"claude-sessions\"" line)
          (cl-pushnew "mcp_tool_call" names :test #'equal))))
    (nreverse names)))

;;; The handover tests

(ert-deftest claude-code-ide-live-test-handover-chain ()
  "CC -> Codex with claude-sessions, Codex -> CC, and the chain of three legs.
Each source reads a codeword with a tool and replies \"done\"; then the
file is deleted, so the codeword is only in a tool result of the source.
Leg 2 (Codex) must read it with the claude-sessions tools; leg 3 (CC)
reads the Codex rollout through the file reference."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-all)
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
          ;; The detail came through the tools of claude-sessions
          (let ((calls (claude-code-ide-live-tests--session-tool-calls rollout)))
            (claude-code-ide-live-tests--log "case 1 rollout %s: claude-sessions calls %S" rollout calls)
            (should calls)))
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
    (claude-code-ide-live-tests--stop-all)))

(ert-deftest claude-code-ide-live-test-handover-file-reference ()
  "CC -> Codex without the session server: the target reads the transcript file."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-all)
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
          ;; The target read the file, not the session server
          (should-not (claude-code-ide-live-tests--session-tool-calls
                       (claude-code-ide-live-tests--transcript target))))))
    (claude-code-ide-live-tests--stop-all)))

(ert-deftest claude-code-ide-live-test-handover-hooks-not-trusted ()
  "A coordinator handover to Codex without trusted hooks is refused, and nothing changes."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-all)
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
    (claude-code-ide-live-tests--stop-all)))

(defun claude-code-ide-live-tests--start-stray (directory)
  "Start `sleep 900' in DIRECTORY outside Emacs, and return its process ID.
The shell that starts it ends at once, so the sleep is no child of Emacs."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory directory)))
      (call-process "sh" nil t nil "-c" "sleep 900 </dev/null >/dev/null 2>&1 & echo $!"))
    (string-to-number (string-trim (buffer-string)))))

(ert-deftest claude-code-ide-live-test-handover-stray ()
  "A stray process in the worktree stops the handover with needs-user; end goes on."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-all)
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
          (should (member stray (mapcar (lambda (s) (plist-get s :pid)) (plist-get status :strays))))
          (should-not (claude-code-ide-live-tests--running-p source))
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
    (claude-code-ide-live-tests--stop-all)))

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
  (claude-code-ide-live-tests--skip-unless-live)
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
        (setq claude-code-ide-live-tests--kill-stage nil)))))

(defun claude-code-ide-live-tests--cli-processes (native-id)
  "Return the process IDs of the CLIs whose command line names NATIVE-ID."
  (cl-remove-if-not
   (lambda (pid)
     (let ((args (alist-get 'args (process-attributes pid))))
       (and (stringp args)
            (string-search native-id args)
            (string-match-p "\\`\\S-*\\(claude\\|codex\\)\\b" args))))
   (list-system-processes)))

(ert-deftest claude-code-ide-live-test-recovery-2-after-kill ()
  "Part 2 of the recovery test: the new Emacs starts only the target.
The registry mode turns on at the start of this Emacs, and its recovery
runs in the first idle moment, before this test.  The test checks that
the source never starts again, that the target runs with its instance
ID, that the handover commits, and that the target has the work."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
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
      (should starts))
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
    (claude-code-ide-live-tests--stop-all)))

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
    (with-selected-frame frame
      (set-window-buffer (frame-root-window frame) buffer))))

(defun claude-code-ide-live-tests--screen (instance-id)
  "Return the screen text of INSTANCE-ID, with runs of blanks as one space."
  (string-trim
   (replace-regexp-in-string
    "[ \t]+" " " (claude-code-ide-codex--screen-text (claude-code-ide-live-tests--buffer instance-id)))))

(defun claude-code-ide-live-tests--dialog-check (instance-id kind state marker)
  "Check that INSTANCE-ID shows the dialog KIND and gets no typed text.
INSTANCE-ID must be in STATE.
STATE is (STATE REASON).  The submit of a prompt that holds MARKER
while the dialog shows must queue it, and the terminal must not show
it.  Return the submit result."
  (claude-code-ide-live-tests--show instance-id)
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
                  instance-id (format "%s: reply with the single word queued" marker) :queue t)))
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
      (let* ((claude-code-ide-mcp-allowed-tools nil)
             (id (claude-code-ide-live-tests--launch
                  trusted 'codex
                  (concat tag "-approval: call the MCP tool mcp__emacs_tools__claude_code_ide_mcp_project_info one time (it is in ALL_TOOLS), then reply with the single word called"))))
        (let* ((result (claude-code-ide-live-tests--dialog-check
                        id 'approval '(waiting-for-user approval) (concat tag "-queued")))
               (request (plist-get result :request-id))
               (start (float-time)))
          ;; The person allows the call; then the queued prompt goes out
          (claude-code-ide-live-tests--send-key id 'return)
          (should (claude-code-ide-live-tests--wait-turn id 0 claude-code-ide-live-tests--turn-limit))
          (should (claude-code-ide-live-tests--wait
                   (lambda () (eq (plist-get (claude-code-ide-control-request-status id request) :result)
                                  'delivered))
                   claude-code-ide-live-tests--turn-limit "the delivery of the queued prompt"))
          (should (claude-code-ide-live-tests--wait-turn id start claude-code-ide-live-tests--turn-limit)))
        (claude-code-ide-live-tests--stop id))
      (claude-code-ide-live-tests--stop-all))))

(ert-deftest claude-code-ide-live-test-codex-dialogs-vterm ()
  "The Codex dialogs in vterm: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--dialogs 'vterm))

(ert-deftest claude-code-ide-live-test-codex-dialogs-eat ()
  "The Codex dialogs in eat: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--dialogs 'eat))

(ert-deftest claude-code-ide-live-test-codex-dialogs-ghostel ()
  "The Codex dialogs in ghostel, in an invisible GUI frame: found, and no typed text."
  :tags '(:live :dialogs)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--dialogs 'ghostel))

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
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-asks-nothing 'eat 'codex))

(ert-deftest claude-code-ide-live-test-stop-asks-nothing-ghostel ()
  "A stop of a Codex instance in ghostel asks no question."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-asks-nothing 'ghostel 'codex))

(ert-deftest claude-code-ide-live-test-stop-asks-nothing-vterm ()
  "A stop of a Codex instance in vterm asks no question."
  :tags '(:live)
  (claude-code-ide-live-tests--skip-unless-live)
  (claude-code-ide-live-tests--stop-asks-nothing 'vterm 'codex))

;;; Running the tests in the daemon

;;;###autoload
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
