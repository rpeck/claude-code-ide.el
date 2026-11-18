;;; claude-code-ide-transcript-tests.el --- Tests for the transcript readers and the handover document  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for claude-code-ide-transcript.el: the CC and Codex readers,
;; the workspace state from Git, and the handover document.  The
;; transcripts in test-fixtures/transcripts/ are synthetic, and all
;; their text starts with cci-test.  Git repositories are made in
;; temporary folders, with the global and system Git configuration
;; turned off.  claude-code-ide-tests.el loads this file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide-transcript)

(defconst claude-code-ide-transcript-tests--fixtures
  (expand-file-name "test-fixtures/transcripts/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Folder of the synthetic transcripts.")

(defconst claude-code-ide-transcript-tests--root "/tmp/cci-test-proj"
  "Working folder that the fixtures name.  It is not created.")

(defun claude-code-ide-transcript-tests--fixture (name)
  "Return the file of the fixture NAME."
  (expand-file-name name claude-code-ide-transcript-tests--fixtures))

(defconst claude-code-ide-transcript-tests--git-environment
  '("GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_AUTHOR_NAME=cci-test" "GIT_AUTHOR_EMAIL=cci-test@example.invalid"
    "GIT_COMMITTER_NAME=cci-test" "GIT_COMMITTER_EMAIL=cci-test@example.invalid")
  "Environment for Git in the tests: no user configuration.")

(defun claude-code-ide-transcript-tests--git (dir &rest args)
  "Run git ARGS in DIR and return its trimmed output.  Signal an error on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eq 0 (apply #'call-process "git" nil t nil args))
        (error "Command git %S failed: %s" args (buffer-string))))
    (string-trim (buffer-string))))

(defun claude-code-ide-transcript-tests--write (file text)
  "Write TEXT to FILE, and make its folder."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(defun claude-code-ide-transcript-tests--commit (dir file text message &optional date)
  "Write TEXT to FILE in DIR and commit it with MESSAGE, at DATE when given."
  (claude-code-ide-transcript-tests--write (expand-file-name file dir) text)
  (claude-code-ide-transcript-tests--git dir "add" file)
  (let ((process-environment
         (append (and date (list (concat "GIT_AUTHOR_DATE=" date)
                                 (concat "GIT_COMMITTER_DATE=" date)))
                 process-environment)))
    (claude-code-ide-transcript-tests--git dir "commit" "-q" "-m" message)))

(defmacro claude-code-ide-transcript-tests--with-dir (var &rest body)
  "Run BODY with VAR bound to a new temporary folder, and remove it after.
Git in BODY uses no user configuration."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "cci-test-transcript-" t)))
         (process-environment (append claude-code-ide-transcript-tests--git-environment
                                      process-environment)))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,var t))))

(defmacro claude-code-ide-transcript-tests--with-repo (var &rest body)
  "Run BODY with VAR bound to a new Git repository on branch cci-test-branch."
  (declare (indent 1))
  `(claude-code-ide-transcript-tests--with-dir ,var
     (claude-code-ide-transcript-tests--git ,var "init" "-q" "-b" "cci-test-branch")
     ,@body))

(defun claude-code-ide-transcript-tests--count (needle haystack)
  "Return how many times the string NEEDLE is in HAYSTACK."
  (let ((count 0) (start 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count) start (match-end 0)))
    count))

(defun claude-code-ide-transcript-tests--before-p (first second text)
  "Return non-nil when FIRST is in TEXT before SECOND."
  (let ((a (string-search first text)) (b (string-search second text)))
    (and a b (< a b))))

;;; Readers

(ert-deftest claude-code-ide-test-transcript-read-claude ()
  "The CC reader returns the turns of people and the assistant, and skips the rest.
Thinking, meta records, CLI output, subagent records, tool results, a
broken line and an unknown record type do not give turns."
  (should
   (equal
    (claude-code-ide-transcript-read-claude
     (claude-code-ide-transcript-tests--fixture "claude-leg1.jsonl")
     claude-code-ide-transcript-tests--root)
    '((:role user :text "cci-test-chain: add mean_of and fmt_report to stats.py."
             :tools nil :time "2026-11-17T10:01:00.000Z")
      (:role assistant
             :text "cci-test: I look at the project first.\n\ncci-test: Done. mean_of and fmt_report are in stats.py."
             :tools ("Bash: git status" "Edit: stats.py")
             :time "2026-11-17T10:04:00.000Z")
      (:role user :text "/model cci-test-model" :tools nil :time "2026-11-17T10:11:00.000Z")
      (:role user :text "cci-test-chain: also add clamp to util.py.\n[image]"
             :tools nil :time "2026-11-17T10:13:00.000Z")
      (:role assistant :text "cci-test: clamp is in util.py." :tools ("Write: util.py")
             :time "2026-11-17T10:15:00.000Z")))))

(ert-deftest claude-code-ide-test-transcript-read-codex ()
  "The Codex reader uses the item_completed events and skips reasoning.
Response items, a broken line, an unknown record type and an unknown
item type do not give turns."
  (let ((turns (claude-code-ide-transcript-read-codex
                (claude-code-ide-transcript-tests--fixture "codex-leg2.jsonl")
                claude-code-ide-transcript-tests--root)))
    (should (= (length turns) 4))
    (should (claude-code-ide-transcript-document-id (plist-get (nth 0 turns) :text)))
    (should (equal (cddr (nth 1 turns))
                   '(:text "ready cci-test-bootstrap-h1"
                           :tools ("apply_patch: add .handover/cci-test-h1-state.md")
                           :time "2026-11-17T11:05:00.000Z")))
    (should (equal (nth 2 turns)
                   '(:role user
                           :text "cci-test-chain: rename fmt_report to format_summary with JSON output."
                           :tools nil :time "2026-11-17T11:10:00.000Z")))
    (should (equal (nth 3 turns)
                   '(:role assistant
                           :text "cci-test: I change stats.py.\n\ncci-test: format_summary returns JSON now."
                           :tools ("exec: python3 -m pytest -q (exit 1)"
                                   "apply_patch: update stats.py"
                                   "mcp: emacs-tools/getDiagnostics")
                           :time "2026-11-17T11:11:00.000Z")))
    (should-not (cl-some (lambda (turn)
                           (string-match-p "reasoning\\|response-item\\|unknown\\|broken"
                                           (or (plist-get turn :text) "")))
                         turns))))

(ert-deftest claude-code-ide-test-transcript-read-codex-legacy ()
  "An imported rollout without item_completed events gives its turns from the events.
A tool call of the import becomes a tool line; its result is left out."
  (should
   (equal (claude-code-ide-transcript-read-codex
           (claude-code-ide-transcript-tests--fixture "codex-legacy.jsonl")
           claude-code-ide-transcript-tests--root)
          '((:role user :text "cci-test-import: read README.md" :tools nil
                   :time "2026-11-17T11:01:00.000Z")
            (:role assistant :text "cci-test: The README names the project."
                   :tools ("Read: file: README.md")
                   :time "2026-11-17T11:03:00.000Z")))))

(ert-deftest claude-code-ide-test-transcript-format-and-read ()
  "The format comes from the file, and `claude-code-ide-transcript-read' uses it."
  (should (eq (claude-code-ide-transcript-format
               (claude-code-ide-transcript-tests--fixture "claude-leg1.jsonl"))
              'claude))
  (should (eq (claude-code-ide-transcript-format
               (claude-code-ide-transcript-tests--fixture "codex-leg2.jsonl"))
              'codex))
  (should (= (length (claude-code-ide-transcript-read
                      (claude-code-ide-transcript-tests--fixture "codex-legacy.jsonl")))
             2))
  (should-not (claude-code-ide-transcript-read "/nonexistent/cci-test.jsonl"))
  (should-not (claude-code-ide-transcript-read nil))
  (claude-code-ide-transcript-tests--with-dir dir
    (let ((file (expand-file-name "cci-test-other.jsonl" dir)))
      (claude-code-ide-transcript-tests--write file "{\"cci-test\": 1}\nnot json\n")
      (should-not (claude-code-ide-transcript-format file))
      (should-not (claude-code-ide-transcript-read file)))))

(ert-deftest claude-code-ide-test-transcript-broken-first-lines ()
  "Broken lines, empty lines and non-object lines at the start do not stop a read."
  (claude-code-ide-transcript-tests--with-dir dir
    (let ((file (expand-file-name "cci-test-broken.jsonl" dir)))
      (claude-code-ide-transcript-tests--write
       file
       (concat "{\"type\":\"user\",\"message\":\n"
               "\n"
               "[\"type\",\"user\"]\n"
               "{\"type\":\"user\",\"sessionId\":\"cci-test\",\"timestamp\":\"2026-11-17T10:00:00Z\","
               "\"message\":{\"role\":\"user\",\"content\":\"cci-test-after-broken\"}}"))
      (should (equal (claude-code-ide-transcript-read file)
                     '((:role user :text "cci-test-after-broken" :tools nil
                              :time "2026-11-17T10:00:00Z")))))))

(ert-deftest claude-code-ide-test-transcript-claude-prompts ()
  "CC user texts become prompts only when a person wrote them."
  (should (equal (claude-code-ide-transcript--claude-clean-prompt
                  "<command-message>cci-test</command-message>\n<command-name>/cci-test</command-name>\n<command-args></command-args>")
                 "/cci-test"))
  (should (equal (claude-code-ide-transcript--claude-clean-prompt
                  "<bash-input>ls cci-test</bash-input>")
                 "! ls cci-test"))
  (should-not (claude-code-ide-transcript--claude-clean-prompt
               "<bash-stdout>cci-test</bash-stdout><bash-stderr></bash-stderr>"))
  (should-not (claude-code-ide-transcript--claude-clean-prompt
               "<system-reminder>cci-test</system-reminder>"))
  (should-not (claude-code-ide-transcript--claude-clean-prompt "  "))
  (should (equal (claude-code-ide-transcript--claude-clean-prompt "  cci-test <b>x</b> ")
                 "cci-test <b>x</b>"))
  (should-not (claude-code-ide-transcript--claude-prompt
               '((type . "user") (isCompactSummary . t)
                 (message (role . "user") (content . "cci-test summary"))))))

(ert-deftest claude-code-ide-test-transcript-tool-lines ()
  "Tool lines are one line, relative to the root, without a leading cd."
  (let ((claude-code-ide-transcript-tool-line-limit 40))
    (should (equal (claude-code-ide-transcript--command
                    "cd '/tmp/cci-test-proj' && grep -r x /tmp/cci-test-proj/src"
                    "/tmp/cci-test-proj")
                   "grep -r x src"))
    (should (equal (claude-code-ide-transcript--command "ls /tmp/cci-test-proj" "/tmp/cci-test-proj")
                   "ls ."))
    (should (equal (claude-code-ide-transcript--command "ls /tmp/cci-test-proj2" "/tmp/cci-test-proj")
                   "ls /tmp/cci-test-proj2"))
    (should (equal (claude-code-ide-transcript--tool-line "Bash" "echo cci-test\necho two")
                   "Bash: echo cci-test echo two"))
    (should (equal (length (claude-code-ide-transcript--tool-line "Bash" (make-string 100 ?x)))
                   40))
    (should (equal (claude-code-ide-transcript--claude-tool
                    '((name . "Grep") (input (pattern . "cci-test") (path . "/tmp/cci-test-proj/lib")))
                    "/tmp/cci-test-proj")
                   "Grep: cci-test in lib"))
    (should (equal (claude-code-ide-transcript--claude-tool
                    '((name . "mcp__cci_test__tool") (input (count . 3) (query . "cci-test q")))
                    nil)
                   "mcp__cci_test__tool: cci-test q"))))

(ert-deftest claude-code-ide-test-transcript-codex-meta ()
  "The Codex session metadata gives the ID, the folder and the Git commit."
  (should (equal (claude-code-ide-transcript-codex-meta
                  (claude-code-ide-transcript-tests--fixture "codex-leg2.jsonl"))
                 '(:id "cci-test-codex-0002" :cwd "/tmp/cci-test-proj"
                       :commit "0123456789abcdef0123456789abcdef01234567"
                       :branch "cci-test-branch" :time "2026-11-17T11:00:00.000Z")))
  (should-not (claude-code-ide-transcript-codex-meta
               (claude-code-ide-transcript-tests--fixture "claude-leg1.jsonl"))))

;;; Workspace state

(ert-deftest claude-code-ide-test-transcript-workspace-state ()
  "The workspace state has the branch, HEAD, status, diff stat, untracked files and log."
  (claude-code-ide-transcript-tests--with-repo dir
    (claude-code-ide-transcript-tests--commit dir "a.txt" "cci-test a\n" "cci-test first")
    (let ((first (claude-code-ide-transcript-tests--git dir "rev-parse" "HEAD")))
      (claude-code-ide-transcript-tests--commit dir "b.txt" "cci-test b\n" "cci-test second")
      (claude-code-ide-transcript-tests--write (expand-file-name "a.txt" dir) "cci-test a2\n")
      (claude-code-ide-transcript-tests--write (expand-file-name "new/c.txt" dir) "cci-test c\n")
      (let ((state (claude-code-ide-transcript-workspace-state dir first)))
        (should (plist-get state :git))
        (should (equal (plist-get state :branch) "cci-test-branch"))
        (should (equal (plist-get state :head)
                       (claude-code-ide-transcript-tests--git dir "rev-parse" "HEAD")))
        (should (equal (plist-get state :head-subject) "cci-test second"))
        (should (equal (plist-get state :status) '(" M a.txt" "?? new/")))
        (should (equal (plist-get state :since) first))
        (should (= (length (plist-get state :diff-stat)) 3))
        (should (string-match-p "a.txt" (nth 0 (plist-get state :diff-stat))))
        (should (string-match-p "b.txt" (nth 1 (plist-get state :diff-stat))))
        (should (equal (plist-get state :untracked) '("new/c.txt")))
        (should (= (length (plist-get state :log)) 2))
        (should (string-match-p "cci-test second" (car (plist-get state :log)))))
      ;; A SINCE that is not a commit gives no diff stat.
      (let ((state (claude-code-ide-transcript-workspace-state dir "cci-test-no-such-commit")))
        (should-not (plist-get state :since))
        (should-not (plist-get state :diff-stat))))))

(ert-deftest claude-code-ide-test-transcript-workspace-state-edge-cases ()
  "A folder outside Git, a repository without commits and a detached HEAD."
  (claude-code-ide-transcript-tests--with-dir dir
    (should (equal (claude-code-ide-transcript-workspace-state dir)
                   (list :worktree dir :git nil))))
  (should-not (plist-get (claude-code-ide-transcript-workspace-state nil) :git))
  (claude-code-ide-transcript-tests--with-repo dir
    (let ((state (claude-code-ide-transcript-workspace-state dir)))
      (should (plist-get state :git))
      (should (eq (plist-get state :head) 'unknown))
      (should (eq (plist-get state :head-subject) 'unknown))
      (should-not (plist-get state :log)))
    (claude-code-ide-transcript-tests--commit dir "a.txt" "cci-test\n" "cci-test one")
    (claude-code-ide-transcript-tests--git dir "checkout" "-q" "--detach")
    (should (eq (plist-get (claude-code-ide-transcript-workspace-state dir) :branch) 'detached))))

(ert-deftest claude-code-ide-test-transcript-git-line-limit ()
  "A long Git listing is cut, and the last line counts the lines left out."
  (let ((claude-code-ide-transcript-git-line-limit 2))
    (should (equal (claude-code-ide-transcript--lines "a\nb\nc\nd")
                   '("a" "b" "... (2 more lines)")))
    (should (equal (claude-code-ide-transcript--lines "a\n\nb") '("a" "b")))
    (should-not (claude-code-ide-transcript--lines nil))))

(ert-deftest claude-code-ide-test-transcript-commit-at ()
  "The start commit is the last commit before a time stamp."
  (claude-code-ide-transcript-tests--with-repo dir
    (claude-code-ide-transcript-tests--commit dir "a.txt" "1\n" "cci-test one"
                                              "2026-01-01T00:00:00Z")
    (let ((one (claude-code-ide-transcript-tests--git dir "rev-parse" "HEAD")))
      (claude-code-ide-transcript-tests--commit dir "a.txt" "2\n" "cci-test two"
                                                "2026-06-01T00:00:00Z")
      (should (equal (claude-code-ide-transcript-commit-at dir "2026-03-01T00:00:00.000Z") one))
      (should (equal (claude-code-ide-transcript-commit-at dir "2026-07-01T00:00:00Z")
                     (claude-code-ide-transcript-tests--git dir "rev-parse" "HEAD")))
      (should-not (claude-code-ide-transcript-commit-at dir "2025-01-01T00:00:00Z"))
      (should-not (claude-code-ide-transcript-commit-at dir "cci-test not a time")))))

;;; The handover document

(defun claude-code-ide-transcript-tests--stub-provider (file)
  "Return a stub `claude' provider whose transcript is FILE."
  (claude-code-ide-provider-create
   :name 'claude :display-name "cci-test stub" :buffer-name-prefix "cci-test"
   :transcript (lambda (_instance what) (if (eq what 'file) file 'unknown))))

(defun claude-code-ide-transcript-tests--chain-document (dir &rest args)
  "Return the document of the three-leg chain in the repository DIR.
The legs are CC, Codex and CC.  The source is an instance of the
third leg.  ARGS are more keyword arguments."
  (let* ((claude-code-ide-provider--registry nil)
         (source (claude-code-ide-instance-create
                  :id "cci-test-instance-3" :provider 'claude
                  :native-id "cci-test-0000-0000-0000-000000000003"
                  :project-root dir :worktree dir)))
    (claude-code-ide-register-provider
     (claude-code-ide-transcript-tests--stub-provider
      (claude-code-ide-transcript-tests--fixture "claude-leg3.jsonl")))
    (apply #'claude-code-ide-transcript-handover-document
           :source source
           :chain (list (list :provider 'claude :instance-id "cci-test-instance-1"
                              :native-id "cci-test-0000-0000-0000-000000000001"
                              :transcript (claude-code-ide-transcript-tests--fixture
                                           "claude-leg1.jsonl"))
                        (list :provider 'codex :instance-id "cci-test-instance-2"
                              :native-id "cci-test-codex-0002"
                              :transcript (claude-code-ide-transcript-tests--fixture
                                           "codex-leg2.jsonl")
                              :handover-id "cci-test-h1" :document-hash "cci-test-hash-h1")
                        ;; The record of the source leg: it gives the handover
                        ;; that started the source.
                        (list :provider 'claude :native-id "cci-test-0000-0000-0000-000000000003"
                              :handover-id "cci-test-h2" :document-hash "cci-test-hash-h2"))
           :context "cci-test-context: the coordinator wants format_summary kept."
           :handover-id "cci-test-h3"
           :target-provider 'codex
           :time 0
           args)))

(ert-deftest claude-code-ide-test-transcript-handover-chain ()
  "A chain of three legs (CC, Codex, CC) gives one document without nesting.
The original first prompt is in it one time, every user prompt is in it
in order, the state summary of the source is in it, and the earlier
documents and the bootstrap turns are not."
  (claude-code-ide-transcript-tests--with-repo dir
    (claude-code-ide-transcript-tests--commit dir "stats.py" "cci-test\n" "cci-test stats")
    (claude-code-ide-transcript-tests--write
     (expand-file-name ".handover/cci-test-h2-state.md" dir)
     "cci-test-summary-h2: format_summary returns JSON; clamp is reverted.\n")
    (let ((doc (claude-code-ide-transcript-tests--chain-document dir)))
      ;; Its own marker only: no nested document.
      (should (= (claude-code-ide-transcript-tests--count "<!-- claude-code-ide-handover-document" doc) 1))
      (should (equal (claude-code-ide-transcript-document-id doc) "cci-test-h3"))
      (dolist (gone '("cci-test-nested-text-h1" "cci-test-nested-text-h2"
                      "cci-test-old-instruction" "cci-test-bootstrap-h1" "cci-test-bootstrap-h2"
                      "cci-test-thinking-text" "cci-test-reasoning-text" "cci-test-sidechain-text"
                      "cci-test-response-item-text" "cci-test-unknown" "cci-test-broken"
                      "cci-test-result-text"))
        (should-not (string-search gone doc)))
      ;; The original first prompt, one time.
      (should (= (claude-code-ide-transcript-tests--count
                  "cci-test-chain: add mean_of and fmt_report to stats.py." doc)
                 1))
      (should (claude-code-ide-transcript-tests--before-p
               "### Original task" "cci-test-chain: add mean_of" doc))
      ;; Every other user prompt, one time each, in order.
      (let ((prompts '("/model cci-test-model"
                       "cci-test-chain: also add clamp to util.py."
                       "cci-test-chain: rename fmt_report to format_summary with JSON output."
                       "cci-test-chain: revert the clamp change from the first session.")))
        (dolist (prompt prompts)
          (should (= (claude-code-ide-transcript-tests--count prompt doc) 1)))
        (cl-loop for (a b) on prompts while b
                 do (should (claude-code-ide-transcript-tests--before-p a b doc))))
      ;; The prompts are named in the latest turns, not repeated.
      (should (string-search "(P1, the original task above.)" doc))
      (should (string-search "(P5 in the list of user prompts above.)" doc))
      ;; The state summary of the previous target, verbatim.
      (should (string-search "> cci-test-summary-h2: format_summary returns JSON; clamp is reverted." doc))
      (should (string-search "### State summary of the previous target (.handover/cci-test-h2-state.md)" doc))
      ;; The header, the legs and the workspace.
      (should (string-search "- Target provider: codex\n" doc))
      (should (string-search "- Time: 1970-01-01T00:00:00Z\n" doc))
      (should (string-search "started by handover cci-test-h1 (sha256 cci-test-hash-h1)" doc))
      (should (string-search "- Source: claude, conversation cci-test-0000-0000-0000-000000000003, instance cci-test-instance-3, started by handover cci-test-h2 (sha256 cci-test-hash-h2)" doc))
      (should (string-search "- Branch: cci-test-branch\n" doc))
      (should (string-search "cci-test stats" doc))
      (should (string-search "?? .handover/" doc))
      (should (string-search (format "- State summary file: `%s`"
                                     (expand-file-name ".handover/cci-test-h3-state.md" dir))
                             doc))
      ;; The parts are in the order of plan section 4.7.
      (cl-loop for (a b) on '("# Handover document" "## Workspace state"
                              "## Context from the coordinator" "## History of the chain"
                              "### Original task" "### State summary" "### User prompts"
                              "### Latest turns" "## Not carried over" "## Instructions")
               while b
               do (should (claude-code-ide-transcript-tests--before-p a b doc)))
      (should (string-search "cci-test-context: the coordinator wants format_summary kept." doc))
      (should (string-search "- Tool exec: python3 -m pytest -q (exit 1)" doc))
      (should (string-search "Then reply `ready`" doc)))))

(ert-deftest claude-code-ide-test-transcript-handover-document-round-trip ()
  "A document names its ID, its summary file and its original task, for the next leg."
  (claude-code-ide-transcript-tests--with-dir dir
    (let ((doc (claude-code-ide-transcript-handover-document
                :source (list :provider 'claude
                              :transcript (claude-code-ide-transcript-tests--fixture
                                           "claude-leg1.jsonl")
                              :worktree dir)
                :handover-id "cci-test-h9" :summary-file "cci-test-state.md")))
      (should (equal (claude-code-ide-transcript-document-id doc) "cci-test-h9"))
      (should (equal (claude-code-ide-transcript-document-summary-file doc) "cci-test-state.md"))
      (should (equal (claude-code-ide-transcript-document-original-task doc)
                     "cci-test-chain: add mean_of and fmt_report to stats.py."))
      (should (string-search "- Target provider: unknown\n" doc))
      (should (string-search "- Legs of the chain: this is the first handover." doc))
      (should (string-search "is not in a Git working tree." doc))
      ;; No state summary part when no handover started the source.
      (should-not (string-search "### State summary" doc)))))

(ert-deftest claude-code-ide-test-transcript-handover-without-chain ()
  "Without a chain, the original task comes from the document that started the source.
A missing state summary file is named, and the nested document is not copied."
  (claude-code-ide-transcript-tests--with-dir dir
    (let ((doc (claude-code-ide-transcript-handover-document
                :source (list :provider 'claude :worktree dir
                              :transcript (claude-code-ide-transcript-tests--fixture
                                           "claude-leg3.jsonl"))
                :handover-id "cci-test-h4")))
      (should (= (claude-code-ide-transcript-tests--count
                  "cci-test-chain: add mean_of and fmt_report to stats.py." doc)
                 1))
      (should-not (string-search "cci-test-nested-text-h2" doc))
      (should-not (string-search "cci-test-bootstrap-h2" doc))
      (should (string-search "### State summary of the previous target (.handover/cci-test-h2-state.md)\n\nThe file does not exist." doc))
      (should (string-search "cci-test-chain: revert the clamp change" doc))
      (should (string-search (expand-file-name ".handover/cci-test-h4-state.md" dir) doc)))))

(ert-deftest claude-code-ide-test-transcript-handover-start-commit ()
  "The diff stat starts at the :start-commit of the source, or at the commit before its first turn."
  (claude-code-ide-transcript-tests--with-repo dir
    (claude-code-ide-transcript-tests--commit dir "a.txt" "1\n" "cci-test one" "2026-11-17T09:00:00Z")
    (let ((one (claude-code-ide-transcript-tests--git dir "rev-parse" "HEAD")))
      (claude-code-ide-transcript-tests--commit dir "b.txt" "2\n" "cci-test two" "2026-11-17T10:30:00Z")
      (let ((leg (list :provider 'claude :worktree dir
                       :transcript (claude-code-ide-transcript-tests--fixture "claude-leg1.jsonl"))))
        ;; The first turn is at 10:01, so the start is commit one.
        (should (string-search (format "### Diff stat since %s (the start of the source)" one)
                               (claude-code-ide-transcript-handover-document :source leg)))
        (should (string-search "The start commit is unknown."
                               (claude-code-ide-transcript-handover-document
                                :source (plist-put (copy-sequence leg) :start-commit "cci-test-none"))))))))

(defun claude-code-ide-transcript-tests--long-transcript (file count)
  "Write a CC transcript with COUNT prompts and replies to FILE."
  (with-temp-file file
    (dotimes (i count)
      (insert (json-encode `((type . "user") (sessionId . "cci-test-long")
                             (timestamp . ,(format "2026-11-17T10:%02d:%02d.000Z" (/ i 60) (% i 60)))
                             (message (role . "user")
                                      (content . ,(format "cci-test-prompt-%03d %s" i
                                                          (make-string 200 ?p))))))
              "\n"
              (json-encode `((type . "assistant") (sessionId . "cci-test-long")
                             (timestamp . ,(format "2026-11-17T11:%02d:%02d.000Z" (/ i 60) (% i 60)))
                             (message (role . "assistant")
                                      (content . [((type . "text")
                                                   (text . ,(format "cci-test-reply-%03d %s" i
                                                                    (make-string 300 ?r))))
                                                  ((type . "tool_use") (name . "Bash")
                                                   (input (command . ,(format "echo cci-test-%03d" i))))]))))
              "\n"))))

(ert-deftest claude-code-ide-test-transcript-handover-budget ()
  "The budget cuts a long history from the old turns, and the fixed parts stay."
  (claude-code-ide-transcript-tests--with-dir dir
    (let ((file (expand-file-name "cci-test-long.jsonl" dir)))
      (claude-code-ide-transcript-tests--long-transcript file 120)
      (let* ((args (list :source (list :provider 'claude :transcript file :worktree dir)
                         :context "cci-test-context-long" :handover-id "cci-test-h5"))
             (full (apply #'claude-code-ide-transcript-handover-document :budget 1000000 args))
             (doc (apply #'claude-code-ide-transcript-handover-document :budget 12000 args)))
        ;; Without a cut, everything is in the document.
        (should (string-search "cci-test-reply-000" full))
        (should-not (string-search "left out" full))
        ;; With the budget, the document fits.
        (should (<= (length doc) 12000))
        (should (> (length doc) 10000))
        ;; The fixed parts stay.
        (dolist (part (list "<!-- claude-code-ide-handover-document id=cci-test-h5 -->"
                            "# Handover document" "## Workspace state" "cci-test-context-long"
                            (concat "> cci-test-prompt-000 " (make-string 200 ?p))
                            "## Not carried over" "## Instructions"
                            "Then reply `ready` and wait for the next prompt."))
          (should (string-search part doc)))
        ;; The newest turns stay, and the oldest go.
        (should (string-search "cci-test-reply-119" doc))
        (should (string-search "- Tool Bash: echo cci-test-119" doc))
        (should-not (string-search "cci-test-reply-000" doc))
        (should-not (string-search "cci-test-reply-060" doc))
        (should (string-match-p "([0-9]+ older turns are left out because of the size budget.)" doc))
        (should (string-match-p "([0-9]+ earlier prompts are left out because of the size budget.)" doc))
        ;; The newest prompt is in the list, and its turn names it.
        (should (= (claude-code-ide-transcript-tests--count "cci-test-prompt-119" doc) 1))
        (should (string-search "(P120 in the list of user prompts above.)" doc))
        ;; A budget below the fixed parts keeps only the fixed parts.
        (let ((tiny (apply #'claude-code-ide-transcript-handover-document :budget 100 args)))
          (should (string-search (concat "> cci-test-prompt-000 " (make-string 200 ?p)) tiny))
          (should (string-search "## Instructions" tiny))
          (should (string-search "cci-test-context-long" tiny))
          (should-not (string-search "### Latest turns" tiny))
          (should-not (string-search "cci-test-reply-" tiny)))))))

(ert-deftest claude-code-ide-test-transcript-fit ()
  "The fit keeps the newest entries and counts the others."
  (should (equal (claude-code-ide-transcript--fit "H" '("aaa" "bbb" "ccc") 100 "(%d out)")
                 '("H\n\naaa\n\nbbb\n\nccc" . 3)))
  (should (equal (claude-code-ide-transcript--fit "H" '("aaa" "bbb" "ccc") 16 "(%d out)")
                 '("H\n\naaa\n\nbbb\n\nccc" . 3)))
  (let ((fit (claude-code-ide-transcript--fit "H" '("aaa" "bbb" "ccc") 15 "(%d out)")))
    (should (equal fit '("H\n\n(2 out)\n\nccc" . 1)))
    (should (<= (length (car fit)) 15)))
  (should (equal (claude-code-ide-transcript--fit "H" '("aaaaaaaaaa") 10 "(%d out)")
                 '("H\n\n(1 out)" . 0)))
  (should-not (claude-code-ide-transcript--fit "Heading" '("aaa") 3 "(%d out)")))

(ert-deftest claude-code-ide-test-transcript-merge-source-leg ()
  "A chain leg of the same conversation gives the source its missing values only."
  (let ((source '(:provider claude :native-id "cci-test-n" :transcript "/cci-test/a.jsonl"))
        (record '(:provider codex :native-id "cci-test-n" :summary-file "cci-test-s.md")))
    (should (claude-code-ide-transcript--same-leg-p source record))
    (should-not (claude-code-ide-transcript--same-leg-p source '(:native-id "cci-test-other")))
    (should (claude-code-ide-transcript--same-leg-p '(:transcript "/cci-test/a.jsonl")
                                                    '(:transcript "/cci-test/a.jsonl")))
    (should-not (claude-code-ide-transcript--same-leg-p '(:provider claude) '(:provider claude)))
    (let ((merged (claude-code-ide-transcript--merge-legs source record)))
      (should (eq (plist-get merged :provider) 'claude))
      (should (equal (plist-get merged :summary-file) "cci-test-s.md"))
      (should (equal (plist-get merged :transcript) "/cci-test/a.jsonl")))))

(ert-deftest claude-code-ide-test-transcript-instance-leg ()
  "An instance gives its leg; its transcript file comes from its provider."
  (let ((claude-code-ide-provider--registry nil)
        (file (claude-code-ide-transcript-tests--fixture "claude-leg1.jsonl")))
    (claude-code-ide-register-provider (claude-code-ide-transcript-tests--stub-provider file))
    (should (equal (claude-code-ide-transcript-instance-leg
                    (claude-code-ide-instance-create :id "cci-test-i" :provider 'claude
                                                     :project-root "/cci-test/p"))
                   (list :provider 'claude :instance-id "cci-test-i" :native-id nil
                         :transcript file :worktree "/cci-test/p")))
    ;; A provider without a transcript operation, or no provider, gives no file.
    (should-not (plist-get (claude-code-ide-transcript-instance-leg
                            (claude-code-ide-instance-create :id "cci-test-j" :provider 'cci-test-none))
                           :transcript))))

(provide 'claude-code-ide-transcript-tests)

;;; claude-code-ide-transcript-tests.el ends here
