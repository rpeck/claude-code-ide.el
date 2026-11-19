;;; claude-code-ide-transcript.el --- Transcript readers and the handover document  -*- lexical-binding: t; -*-

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

;; This file reads the transcripts of the coding-agent CLIs and writes
;; the handover document from them.
;;
;; - The readers turn a transcript into a list of turns.  Each turn is
;;   a plist (:role ROLE :text TEXT :tools LINES :time TIME).  ROLE is
;;   `user' or `assistant', TEXT is a string or nil, LINES is a list of
;;   strings with one line for each tool call, and TIME is the time
;;   stamp string of the transcript, or nil.  Thinking and reasoning are
;;   left out.  The readers are tolerant: a broken line or a record of
;;   an unknown type is skipped, and the read continues.
;; - `claude-code-ide-transcript-workspace-state' reads the Git state of
;;   a working tree.
;; - `claude-code-ide-transcript-handover-document' writes the handover
;;   document of plan section 4.7.  docs/handover-document.md describes
;;   its parts, the legs of a chain, and the size budget.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)

(defgroup claude-code-ide-transcript nil
  "Transcript readers and the handover document."
  :group 'claude-code-ide
  :prefix "claude-code-ide-transcript-")

(defcustom claude-code-ide-transcript-budget 100000
  "Size budget of a handover document, in characters.
The budget cuts the user prompts of the chain, the state summary and
the latest turns.  It never cuts the header, the workspace state, the
coordinator context, the references to the source sessions, the
original first prompt, the \"not carried over\" list or the
instructions."
  :type 'integer
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-transcript-prompt-limit 2000
  "Most characters of one user prompt in the list of user prompts."
  :type 'integer
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-transcript-turn-limit 4000
  "Most characters of the text of one turn in the latest turns."
  :type 'integer
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-transcript-tool-line-limit 200
  "Most characters of one tool call line."
  :type 'integer
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-transcript-git-line-limit 200
  "Most lines of each Git listing in the workspace state.
This is a safety limit for very large listings, not a part of the size
budget."
  :type 'integer
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-transcript-summary-file-format ".handover/%s-state.md"
  "File for the state summary of the target when the caller gives none.
%s is the handover ID.  A relative name is relative to the worktree."
  :type 'string
  :group 'claude-code-ide-transcript)

;;; Common helpers

(defun claude-code-ide-transcript--parse-line (line)
  "Return the JSON object on LINE as an alist, or nil.
A line that is not a JSON object gives nil."
  (let ((value (condition-case nil
                   (json-parse-string line :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)
                 (error nil))))
    (and (consp value) (consp (car value)) value)))

(defun claude-code-ide-transcript--map-records (file regexp function)
  "Call FUNCTION with each JSON object of the JSONL FILE, in order.
Only lines that match REGEXP are parsed, when REGEXP is non-nil.  A
line that does not parse, and a record for which FUNCTION signals an
error, are skipped.  Return the number of lines of FILE."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8)
          (lines 0))
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (setq lines (1+ lines))
      (let ((end (line-end-position)))
        (when (and (< (point) end)
                   (or (null regexp)
                       (save-excursion (re-search-forward regexp end t))))
          (when-let* ((record (claude-code-ide-transcript--parse-line
                               (buffer-substring-no-properties (point) end))))
            ;; One bad record does not stop the read.
            (condition-case nil
                (funcall function record)
              (error nil)))))
      (forward-line 1))
      lines)))

(defun claude-code-ide-transcript--add (turns role text tools time)
  "Add a turn to TURNS, which is newest first, and return TURNS.
ROLE, TEXT, TOOLS and TIME are those of the turn.  An assistant part
that follows an assistant turn joins that turn.  A part without text
and without tools adds nothing."
  (let ((text (and text (let ((trimmed (string-trim text)))
                          (unless (string-empty-p trimmed) trimmed))))
        (last (car turns)))
    (cond
     ((and (null text) (null tools)) turns)
     ((and (eq role 'assistant) last (eq (plist-get last :role) 'assistant))
      (when text
        (plist-put last :text (if-let* ((old (plist-get last :text)))
                                  (concat old "\n\n" text)
                                text)))
      (when tools
        (plist-put last :tools (append (plist-get last :tools) tools)))
      turns)
     (t (cons (list :role role :text text :tools tools :time time) turns)))))

(defun claude-code-ide-transcript--one-line (text limit)
  "Return TEXT on one line, cut to LIMIT characters."
  (let ((line (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))
    (if (> (length line) limit)
        (concat (substring line 0 (max 0 (- limit 3))) "...")
      line)))

(defconst claude-code-ide-transcript--path-char "[:alnum:]._~+@-"
  "Characters, other than /, that can be part of a file name in a command.")

(defun claude-code-ide-transcript--relative-text (text root)
  "Return TEXT with the directory ROOT removed from its absolute paths.
ROOT followed by / is removed, and ROOT alone becomes \".\".  ROOT
counts only as a whole path: /a/proj does not change /a/proj-other,
/a/proj.bak or /b/a/proj."
  (if (and root (stringp text))
      (let* ((case-fold-search nil)
             (other (concat "[^/" claude-code-ide-transcript--path-char "]"))
             (regexp (concat "\\(\\`\\|" other "\\)"
                             (regexp-quote (directory-file-name (expand-file-name root)))
                             "\\(/\\|\\'\\|" other "\\)"))
             (start 0)
             parts)
        (while (string-match regexp text start)
          (let ((slash (equal (match-string 2 text) "/")))
            (push (substring text start (match-end 1)) parts)
            (push (if slash "" ".") parts)
            ;; The character after ROOT can start the next match.
            (setq start (if slash (match-end 0) (match-beginning 2)))))
        (push (substring text start) parts)
        (apply #'concat (nreverse parts)))
    text))

(defun claude-code-ide-transcript--path (path root)
  "Return PATH relative to ROOT when it is inside ROOT, else PATH."
  (cond
   ((not (stringp path)) "")
   ((and root (file-name-absolute-p path)
         (string-prefix-p (file-name-as-directory (expand-file-name root))
                          (expand-file-name path)))
    (file-relative-name path root))
   (t path)))

(defun claude-code-ide-transcript--command (command root)
  "Return the shell COMMAND without a leading `cd DIR &&' and relative to ROOT."
  (if (stringp command)
      (let ((command (string-trim command)))
        (when (string-match "\\`cd +\\(\"[^\"]*\"\\|'[^']*'\\|[^ ;&|]+\\) *&& *" command)
          (setq command (substring command (match-end 0))))
        (claude-code-ide-transcript--relative-text command root))
    ""))

(defun claude-code-ide-transcript--tool-line (name detail)
  "Return the one-line form of the tool call NAME with DETAIL."
  (claude-code-ide-transcript--one-line
   (if (and (stringp detail) (not (string-empty-p (string-trim detail))))
       (format "%s: %s" name detail)
     (format "%s" name))
   claude-code-ide-transcript-tool-line-limit))

(defun claude-code-ide-transcript--first-string (alist)
  "Return the first string value of ALIST, or nil."
  (cl-loop for (_key . value) in (and (listp alist) alist)
           when (stringp value) return value))

;;; Claude Code transcripts

(defconst claude-code-ide-transcript--claude-line-regexp
  "\"type\" *: *\"\\(?:user\\|assistant\\)\""
  "Lines of a CC transcript that can hold a turn.")

(defconst claude-code-ide-transcript--claude-skip-tags
  '("local-command-stdout" "local-command-stderr" "local-command-caveat"
    "system-reminder" "task-notification" "bash-stdout" "bash-stderr"
    "bash-notification" "user-prompt-submit-hook")
  "Leading tags of CC user texts that the CLI wrote, not a person.")

(defconst claude-code-ide-transcript--interrupt-marker
  "[Request interrupted by user"
  "Start of the text that the CC CLI writes to the transcript after an interrupt.
It is the same text as `claude-code-ide-session-status--interrupt-marker'.
That file is not loaded here, because it loads the main file, which
loads this file.")

(defun claude-code-ide-transcript--between (text open close)
  "Return the text between the first OPEN and the next CLOSE in TEXT, or nil.
The search uses string positions, so that a very large TEXT cannot
overflow the regexp stack."
  (when-let* ((start (string-search open text))
              (from (+ start (length open)))
              (end (string-search close text from)))
    (substring text from end)))

(defun claude-code-ide-transcript--claude-clean-prompt (text)
  "Return the CC user TEXT as a prompt, or nil when no person wrote it.
A slash command becomes \"/NAME ARGS\" and a shell escape \"! COMMAND\".
A text of the CLI, such as command output, a reminder or an interrupt
marker, gives nil."
  (let ((text (string-trim text)))
    (cond
     ((string-empty-p text) nil)
     ((string-prefix-p claude-code-ide-transcript--interrupt-marker text) nil)
     ((string-prefix-p "<command-" text)
      (when-let* ((name (claude-code-ide-transcript--between
                         text "<command-name>" "</command-name>")))
        (let ((name (string-trim name))
              (args (string-trim (or (claude-code-ide-transcript--between
                                      text "<command-args>" "</command-args>")
                                     ""))))
          (if (string-empty-p args) name (concat name " " args)))))
     ((string-prefix-p "<bash-input>" text)
      (when-let* ((command (claude-code-ide-transcript--between
                            text "<bash-input>" "</bash-input>")))
        (concat "! " (string-trim command))))
     ((and (string-match "\\`<\\([a-zA-Z_-]+\\)>" text)
           (member (match-string 1 text) claude-code-ide-transcript--claude-skip-tags))
      nil)
     (t text))))

(defun claude-code-ide-transcript--claude-prompt (record)
  "Return the prompt that a person gave in the CC user RECORD, or nil.
Meta records, tool results, compaction summaries, subagent records and
messages of the CLI give nil.  Each text block is cleaned on its own,
so a block of the CLI drops only itself."
  (unless (or (alist-get 'isMeta record)
              (alist-get 'isSidechain record)
              (alist-get 'isCompactSummary record)
              (alist-get 'toolUseResult record)
              (equal (alist-get 'promptSource record) "system"))
    (let ((content (alist-get 'content (alist-get 'message record))))
      (cond
       ((stringp content) (claude-code-ide-transcript--claude-clean-prompt content))
       ((listp content)
        (let (parts)
          (dolist (block content)
            (pcase (and (listp block) (alist-get 'type block))
              ("text" (when-let* ((text (and (stringp (alist-get 'text block))
                                             (claude-code-ide-transcript--claude-clean-prompt
                                              (alist-get 'text block)))))
                        (push text parts)))
              ("image" (push "[image]" parts))
              ("document" (push "[document]" parts))))
          (and parts (string-join (nreverse parts) "\n"))))))))

(defun claude-code-ide-transcript--claude-tool (block root)
  "Return the tool call line of the CC tool_use BLOCK, with paths relative to ROOT."
  (let* ((name (or (alist-get 'name block) "tool"))
         (input (alist-get 'input block))
         (get (lambda (key) (alist-get key input))))
    (claude-code-ide-transcript--tool-line
     name
     (pcase name
       ("Bash" (claude-code-ide-transcript--command (funcall get 'command) root))
       ((or "Read" "Edit" "Write" "MultiEdit")
        (claude-code-ide-transcript--path (funcall get 'file_path) root))
       ("NotebookEdit" (claude-code-ide-transcript--path (funcall get 'notebook_path) root))
       ((or "Grep" "Glob")
        (string-join (delq nil (list (funcall get 'pattern)
                                     (and (stringp (funcall get 'path))
                                          (claude-code-ide-transcript--path
                                           (funcall get 'path) root))))
                     " in "))
       ((or "Task" "Agent") (funcall get 'description))
       ("WebFetch" (funcall get 'url))
       ("WebSearch" (funcall get 'query))
       (_ (claude-code-ide-transcript--relative-text
           (claude-code-ide-transcript--first-string input) root))))))

(defun claude-code-ide-transcript--claude-assistant (record root)
  "Return (TEXT . TOOLS) of the CC assistant RECORD, or nil for a subagent.
Thinking blocks are left out.  Tool paths are relative to ROOT."
  (unless (alist-get 'isSidechain record)
    (let ((content (alist-get 'content (alist-get 'message record)))
          texts tools)
      (if (stringp content)
          (push content texts)
        (dolist (block content)
          (pcase (and (listp block) (alist-get 'type block))
            ("text" (when (stringp (alist-get 'text block))
                      (push (alist-get 'text block) texts)))
            ("tool_use" (push (claude-code-ide-transcript--claude-tool block root) tools)))))
      (cons (and texts (string-join (nreverse texts) "\n\n"))
            (nreverse tools)))))

(defun claude-code-ide-transcript-read-claude (file &optional root)
  "Return the turns of the Claude Code transcript FILE, oldest first.
Tool paths inside ROOT are relative to ROOT.  See the commentary of
this file for the form of a turn."
  (plist-get (claude-code-ide-transcript--read-claude-full file root) :turns))

(defun claude-code-ide-transcript--read-claude-full (file root)
  "Return (:turns TURNS :records LINES) of the Claude Code transcript FILE.
TURNS are those of `claude-code-ide-transcript-read-claude' with ROOT,
and LINES is the number of lines of FILE."
  (let (turns records)
    (setq
     records
     (claude-code-ide-transcript--map-records
     file claude-code-ide-transcript--claude-line-regexp
     (lambda (record)
       (let ((time (alist-get 'timestamp record)))
         (pcase (alist-get 'type record)
           ("user"
            (when-let* ((text (claude-code-ide-transcript--claude-prompt record)))
              (setq turns (claude-code-ide-transcript--add turns 'user text nil time))))
           ("assistant"
            (when-let* ((part (claude-code-ide-transcript--claude-assistant record root)))
              (setq turns (claude-code-ide-transcript--add
                           turns 'assistant (car part) (cdr part) time)))))))))
    (list :turns (nreverse turns) :records records)))

;;; Codex rollouts

(defconst claude-code-ide-transcript--codex-line-regexp
  "\"type\" *: *\"\\(?:item_completed\\|user_message\\|agent_message\\|task_started\\|session_meta\\)\""
  "Lines of a Codex rollout that can hold a turn or the session metadata.")

(defun claude-code-ide-transcript--codex-texts (content)
  "Return the texts of the Codex item CONTENT list, joined, or nil."
  (let ((texts (delq nil (mapcar (lambda (part)
                                   (and (listp part)
                                        (stringp (alist-get 'text part))
                                        (alist-get 'text part)))
                                 (and (listp content) content)))))
    (and texts (string-join texts "\n\n"))))

(defun claude-code-ide-transcript--codex-command (item root)
  "Return the tool line of the Codex CommandExecution ITEM.
Paths are relative to ROOT."
  (let* ((command (alist-get 'command item))
         (text (cond
                ((stringp command) command)
                ;; The usual form is (SHELL "-lc" SCRIPT).
                ((and (listp command) (= (length command) 3)
                      (member (nth 1 command) '("-lc" "-c")))
                 (nth 2 command))
                ((listp command)
                 (mapconcat (lambda (part) (format "%s" part)) command " "))))
         (exit (alist-get 'exit_code item)))
    (claude-code-ide-transcript--tool-line
     "exec"
     (concat (claude-code-ide-transcript--command text root)
             (if (and (integerp exit) (/= exit 0)) (format " (exit %d)" exit) "")))))

(defun claude-code-ide-transcript--codex-tools (item root)
  "Return the tool lines of the Codex ITEM, with paths relative to ROOT.
An item type that is not known gives nil."
  (pcase (alist-get 'type item)
    ("CommandExecution" (list (claude-code-ide-transcript--codex-command item root)))
    ("FileChange"
     (mapcar (lambda (change)
               (claude-code-ide-transcript--tool-line
                "apply_patch"
                (format "%s %s"
                        (or (and (listp (cdr change)) (alist-get 'type (cdr change))) "change")
                        (claude-code-ide-transcript--path (format "%s" (car change)) root))))
             (and (listp (alist-get 'changes item)) (alist-get 'changes item))))
    ("McpToolCall"
     (list (claude-code-ide-transcript--tool-line
            "mcp" (format "%s/%s" (or (alist-get 'server item) "?")
                          (or (alist-get 'tool item) "?")))))
    ("CollabAgentToolCall"
     (list (claude-code-ide-transcript--tool-line "agent" (alist-get 'tool item))))
    ("SubAgentActivity"
     (list (claude-code-ide-transcript--tool-line "subagent" (alist-get 'kind item))))))

(defconst claude-code-ide-transcript--import-call-open "[external_agent_tool_call:"
  "Start of a tool call that an import from CC wrote as assistant text.")

(defconst claude-code-ide-transcript--import-call-close "[/external_agent_tool_call]"
  "End of a tool call that an import from CC wrote as assistant text.")

(defconst claude-code-ide-transcript--import-result-open "[external_agent_tool_result"
  "Start of a tool result that an import from CC wrote as assistant text.")

(defconst claude-code-ide-transcript--import-result-close "[/external_agent_tool_result]"
  "End of a tool result that an import from CC wrote as assistant text.")

(defun claude-code-ide-transcript--codex-legacy-agent (text root)
  "Return (TEXT . TOOLS) of the agent message TEXT of an imported rollout.
The import writes tool calls and results as marked text: a call becomes
a tool line, and a result is left out.  A block without its end marker
lasts to the end of TEXT.  Paths are relative to ROOT.  The markers are
found with string positions, so a very large result cannot overflow
the regexp stack."
  (let ((pos 0) (size (length text)) kept tools)
    (while (< pos size)
      (let* ((call (string-search claude-code-ide-transcript--import-call-open text pos))
             (result (string-search claude-code-ide-transcript--import-result-open text pos))
             (next (if (and call result) (min call result) (or call result))))
        (if (null next)
            (setq kept (cons (substring text pos) kept)
                  pos size)
          (push (substring text pos next) kept)
          (let* ((call-p (eql next call))
                 (close (if call-p
                            claude-code-ide-transcript--import-call-close
                          claude-code-ide-transcript--import-result-close))
                 (end (or (string-search close text next) size))
                 (header-end (string-search "]" text next)))
            (when call-p
              (let* ((name-start (+ next (length claude-code-ide-transcript--import-call-open)))
                     (name-end (if (and header-end (< header-end end)) header-end end))
                     (body (substring text (min end (1+ name-end)) end)))
                (push (claude-code-ide-transcript--tool-line
                       (string-trim (substring text name-start name-end))
                       (claude-code-ide-transcript--relative-text
                        (string-join (split-string body "\n" t "[ \t]+") "; ")
                        root))
                      tools)))
            (setq pos (min size (+ end (length close))))))))
    (cons (string-replace "<EXTERNAL SESSION IMPORTED>" ""
                          (apply #'concat (nreverse kept)))
          (nreverse tools))))

(defun claude-code-ide-transcript--codex-item-turn (turns time item root)
  "Add the Codex ITEM of TIME to TURNS, newest first, and return TURNS.
Paths are relative to ROOT."
  (pcase (alist-get 'type item)
    ("UserMessage"
     (claude-code-ide-transcript--add
      turns 'user (claude-code-ide-transcript--codex-texts (alist-get 'content item)) nil time))
    ("AgentMessage"
     (claude-code-ide-transcript--add
      turns 'assistant (claude-code-ide-transcript--codex-texts (alist-get 'content item))
      nil time))
    (_ (if-let* ((tools (claude-code-ide-transcript--codex-tools item root)))
           (claude-code-ide-transcript--add turns 'assistant nil tools time)
         turns))))

(defun claude-code-ide-transcript--codex-event-turn (turns time payload root)
  "Add the Codex user_message or agent_message PAYLOAD of TIME to TURNS.
TURNS is newest first; return it.  Paths are relative to ROOT."
  (let ((message (alist-get 'message payload)))
    (cond
     ((not (stringp message)) turns)
     ((equal (alist-get 'type payload) "user_message")
      (claude-code-ide-transcript--add turns 'user message nil time))
     (t (let ((part (claude-code-ide-transcript--codex-legacy-agent message root)))
          (claude-code-ide-transcript--add turns 'assistant (car part) (cdr part) time))))))

(defun claude-code-ide-transcript--codex-meta-of (payload)
  "Return the plist of the Codex session_meta PAYLOAD."
  (let ((git (alist-get 'git payload)))
    (list :id (alist-get 'id payload)
          :cwd (alist-get 'cwd payload)
          :commit (and (listp git) (alist-get 'commit_hash git))
          :branch (and (listp git) (alist-get 'branch git))
          :time (alist-get 'timestamp payload))))

(defun claude-code-ide-transcript--codex-history-end (entries)
  "Return the position in ENTRIES where the item_completed records take over.
ENTRIES are (KIND TIME VALUE) lists, oldest first.  An imported rollout
has only events up to its first item; a later resume writes items, and
can also write events for the same messages.  The position is that of
the task_started record of the turn with the first item, else that of
the first item, else the length of ENTRIES."
  (let ((first-item (cl-position 'item entries :key #'car)))
    (if (null first-item)
        (length entries)
      (or (cl-position 'task entries :key #'car :end first-item :from-end t)
          first-item))))

(defun claude-code-ide-transcript--read-codex-full (file root)
  "Return (:turns TURNS :meta META :records LINES) of the Codex rollout FILE.
The file is read one time.  See `claude-code-ide-transcript-read-codex'
for TURNS and ROOT, and `claude-code-ide-transcript-codex-meta' for
META.  LINES is the number of lines of FILE."
  (let (entries meta records)
    (setq
     records
     (claude-code-ide-transcript--map-records
     file claude-code-ide-transcript--codex-line-regexp
     (lambda (record)
       (let ((payload (alist-get 'payload record))
             (time (alist-get 'timestamp record))
             (type (alist-get 'type record)))
         (when (listp payload)
           (cond
            ((equal type "session_meta")
             (unless meta (setq meta (claude-code-ide-transcript--codex-meta-of payload))))
            ((not (equal type "event_msg")))
            ((equal (alist-get 'type payload) "item_completed")
             (when (listp (alist-get 'item payload))
               (push (list 'item time (alist-get 'item payload)) entries)))
            ((equal (alist-get 'type payload) "task_started")
             (push (list 'task time nil) entries))
            ((member (alist-get 'type payload) '("user_message" "agent_message"))
             (push (list 'event time payload) entries))))))))
    (let* ((entries (nreverse entries))
           (history-end (claude-code-ide-transcript--codex-history-end entries))
           (first-item t)
           (turns nil))
      (cl-loop
       for entry in entries
       for position from 0
       do (let ((kind (nth 0 entry)) (time (nth 1 entry)) (value (nth 2 entry)))
            (condition-case nil
                (cond
                 ((and (< position history-end) (eq kind 'event))
                  (setq turns (claude-code-ide-transcript--codex-event-turn turns time value root)))
                 ((and (>= position history-end) (eq kind 'item))
                  (let ((last (car turns))
                        (next (claude-code-ide-transcript--codex-item-turn nil time value root)))
                    ;; The first item can repeat the last event before it.
                    (unless (and first-item next last
                                 (eq (plist-get last :role) (plist-get (car next) :role))
                                 (plist-get (car next) :text)
                                 (string-suffix-p (plist-get (car next) :text)
                                                  (or (plist-get last :text) "")))
                      (setq turns (claude-code-ide-transcript--codex-item-turn
                                   turns time value root)))
                    (setq first-item nil))))
              ;; One bad record does not stop the read.
              (error nil))))
      (list :turns (nreverse turns) :meta meta :records records))))

(defun claude-code-ide-transcript-read-codex (file &optional root)
  "Return the turns of the Codex rollout FILE, oldest first.
The turns come from the `item_completed' events.  The part before the
first such event (the history of an imported rollout, with history
mode legacy) comes from the `user_message' and `agent_message' events.
Reasoning is left out.  Tool paths inside ROOT are relative to ROOT."
  (plist-get (claude-code-ide-transcript--read-codex-full file root) :turns))

(defun claude-code-ide-transcript-codex-meta (file)
  "Return the session metadata of the Codex rollout FILE as a plist, or nil.
The keys are :id, :cwd, :commit, :branch and :time.  Only the start of
FILE is read, because the metadata is its first record."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file nil 0 4194304))
    (goto-char (point-min))
    (catch 'found
      (dotimes (_ 20)
        (let ((record (claude-code-ide-transcript--parse-line
                       (buffer-substring-no-properties (point) (line-end-position)))))
          (when (equal (alist-get 'type record) "session_meta")
            (throw 'found (claude-code-ide-transcript--codex-meta-of
                           (alist-get 'payload record)))))
        (forward-line 1))
      nil)))

;;; Format of a transcript

(defvar claude-code-ide-transcript-readers
  '((claude . claude-code-ide-transcript-read-claude)
    (codex . claude-code-ide-transcript-read-codex))
  "Alist of (FORMAT . READER).
FORMAT is the name of the provider that writes the transcript.  READER
is called with the file and the root directory for relative paths, and
returns the turns.")

(defun claude-code-ide-transcript-format (file)
  "Return the format of the transcript FILE: `claude', `codex', or nil.
The format comes from the first records that parse."
  (catch 'format
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file nil 0 262144))
      (goto-char (point-min))
      (let ((count 0))
        (while (and (not (eobp)) (< count 50))
          (when-let* ((record (claude-code-ide-transcript--parse-line
                               (buffer-substring-no-properties (point) (line-end-position)))))
            (setq count (1+ count))
            (let ((type (alist-get 'type record)))
              (cond
               ((and (assq 'payload record)
                     (member type '("session_meta" "event_msg" "response_item" "turn_context")))
                (throw 'format 'codex))
               ((or (assq 'sessionId record)
                    (member type '("user" "assistant" "summary" "custom-title")))
                (throw 'format 'claude)))))
          (forward-line 1))))
    nil))

(defun claude-code-ide-transcript-read (file &optional format root)
  "Return the turns of the transcript FILE, oldest first.
FORMAT is a key of `claude-code-ide-transcript-readers', or nil to find
it from the file.  Tool paths inside ROOT are relative to ROOT.  A file
that does not exist or has no known format gives nil."
  (when (and (stringp file) (file-readable-p file))
    (let* ((format (or format (claude-code-ide-transcript-format file)))
           (reader (alist-get format claude-code-ide-transcript-readers)))
      (and reader (funcall reader file root)))))

;;; Workspace state

(defun claude-code-ide-transcript--git (dir &rest args)
  "Return the output of git ARGS in DIR without its final newlines, or nil.
A failed command gives nil."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment)))
      (when (eq 0 (condition-case nil
                      (apply #'process-file "git" nil (list t nil) nil args)
                    (error nil)))
        (string-trim-right (buffer-string))))))

(defun claude-code-ide-transcript--lines (text)
  "Return the non-empty lines of TEXT.
There are at most `claude-code-ide-transcript-git-line-limit' lines.  A
cut list ends with a line that counts the lines left out."
  (let* ((lines (and text (split-string text "\n" t)))
         (limit claude-code-ide-transcript-git-line-limit))
    (if (> (length lines) limit)
        (append (cl-subseq lines 0 limit)
                (list (format "... (%d more lines)" (- (length lines) limit))))
      lines)))

(defun claude-code-ide-transcript--time-for-git (time)
  "Return the time stamp string TIME in a form that git accepts, or nil."
  (when-let* ((value (and (stringp time) (ignore-errors (encode-time (iso8601-parse time))))))
    (format-time-string "%Y-%m-%d %H:%M:%S +0000" value t)))

(defun claude-code-ide-transcript-commit-at (dir time)
  "Return the last commit of HEAD in DIR made before TIME, or nil.
TIME is an ISO 8601 time stamp string."
  (when-let* ((before (claude-code-ide-transcript--time-for-git time)))
    (let ((commit (claude-code-ide-transcript--git
                   dir "rev-list" "-n" "1" "--first-parent"
                   (concat "--before=" before) "HEAD")))
      (and commit (not (string-empty-p commit)) commit))))

(defun claude-code-ide-transcript-workspace-state (dir &optional since)
  "Return the Git state of the working tree DIR as a plist.
SINCE is a commit for the diff stat, or nil.  The keys are:
:worktree (the top directory), :git (nil when DIR is not in a Git
working tree; then no other key follows), :branch (a string, or
`detached'), :head and :head-subject (or `unknown' before the first
commit), :status (the lines of git status --porcelain), :since (the
full ID of SINCE, or nil when it is not a commit), :diff-stat (the
lines of git diff --stat SINCE), :untracked (the untracked files) and
:log (the lines of git log --oneline -n 20)."
  (let ((top (and (stringp dir) (file-directory-p dir)
                  (claude-code-ide-transcript--git dir "rev-parse" "--show-toplevel"))))
    (if (not top)
        (list :worktree dir :git nil)
      (let* ((head (claude-code-ide-transcript--git top "rev-parse" "--verify" "-q" "HEAD"))
             (branch (claude-code-ide-transcript--git top "branch" "--show-current"))
             (since (and since
                         (claude-code-ide-transcript--git
                          top "rev-parse" "--verify" "-q" (concat since "^{commit}")))))
        (list :worktree top
              :git t
              :branch (if (or (null branch) (string-empty-p branch)) 'detached branch)
              :head (or head 'unknown)
              :head-subject (or (and head (claude-code-ide-transcript--git
                                           top "log" "-1" "--format=%s" "HEAD"))
                                'unknown)
              :status (claude-code-ide-transcript--lines
                       (claude-code-ide-transcript--git top "status" "--porcelain"))
              :since since
              :diff-stat (and since (claude-code-ide-transcript--lines
                                     (claude-code-ide-transcript--git
                                      top "diff" "--stat" since)))
              :untracked (claude-code-ide-transcript--lines
                          (claude-code-ide-transcript--git
                           top "ls-files" "--others" "--exclude-standard"))
              :log (and head (claude-code-ide-transcript--lines
                              (claude-code-ide-transcript--git
                               top "log" "--oneline" "-n" "20"))))))))

;;; Legs of a chain

;; A leg is one native conversation of a chain, as a plist:
;;   :provider      provider name, for example `claude' or `codex'
;;   :instance-id   instance ID, or nil
;;   :native-id     native conversation ID, or nil
;;   :transcript    transcript file, or nil
;;   :worktree      working tree, or nil
;;   :handover-id   ID of the handover document that started the leg,
;;                  or nil for the first leg
;;   :document-hash SHA-256 of that document, or nil
;;   :summary-file  state summary that the leg wrote in its first turn
;;   :start-commit  HEAD when the leg started, or nil

(defun claude-code-ide-transcript--instance-file (instance)
  "Return the transcript file of INSTANCE from its provider, or nil."
  (when-let* ((name (claude-code-ide-instance-provider instance))
              (provider (if (claude-code-ide-provider-p name)
                            name
                          (claude-code-ide-get-provider name)))
              (file (ignore-errors
                      (claude-code-ide-provider-call provider 'transcript instance 'file))))
    (and (stringp file) (file-readable-p file) file)))

(defun claude-code-ide-transcript-instance-leg (instance)
  "Return the leg plist of the current conversation of INSTANCE."
  (let ((provider (claude-code-ide-instance-provider instance)))
    (list :provider (if (claude-code-ide-provider-p provider)
                        (claude-code-ide-provider-name provider)
                      provider)
          :instance-id (claude-code-ide-instance-id instance)
          :native-id (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance))
          :transcript (claude-code-ide-transcript--instance-file instance)
          :worktree (or (claude-code-ide-known-or-nil (claude-code-ide-instance-worktree instance))
                        (claude-code-ide-known-or-nil
                         (claude-code-ide-instance-project-root instance))))))

(defun claude-code-ide-transcript--leg (leg)
  "Return LEG as a leg plist.  LEG is a plist or an instance descriptor."
  (if (claude-code-ide-instance-p leg) (claude-code-ide-transcript-instance-leg leg) leg))

(defun claude-code-ide-transcript--same-leg-p (a b)
  "Return non-nil when the legs A and B are the same native conversation."
  (let ((id-a (plist-get a :native-id)) (id-b (plist-get b :native-id))
        (file-a (plist-get a :transcript)) (file-b (plist-get b :transcript)))
    (or (and id-a id-b (equal id-a id-b))
        (and (stringp file-a) (stringp file-b)
             (equal (expand-file-name file-a) (expand-file-name file-b))))))

(defun claude-code-ide-transcript--merge-legs (primary secondary)
  "Return PRIMARY with the values of SECONDARY for the keys that it lacks."
  (let ((result (copy-sequence primary)))
    (cl-loop for (key value) on secondary by #'cddr
             unless (plist-get result key)
             do (setq result (plist-put result key value)))
    result))

;;; Handover documents in transcripts

(defconst claude-code-ide-transcript--marker-format
  "<!-- claude-code-ide-handover-document id=%s -->"
  "First line of each handover document.  %s is the handover ID.")

(defconst claude-code-ide-transcript--marker-regexp
  "\\`[ \t\n]*<!-- claude-code-ide-handover-document id=\\([^ \n]+\\) -->[ \t]*$"
  "Regexp that finds the marker of a handover document on the first line.")

(defun claude-code-ide-transcript-document-id (text)
  "Return the handover ID when TEXT is a handover document, else nil.
TEXT is a document when its first line is the marker line.  A marker
in a later line, for example in a quoted text, does not count."
  (and (stringp text)
       (let ((case-fold-search nil))
         (string-match claude-code-ide-transcript--marker-regexp text))
       (match-string 1 text)))

(defun claude-code-ide-transcript-document-summary-file (text)
  "Return the state summary file that the handover document TEXT names, or nil."
  (and (stringp text)
       (string-match "^- State summary file: `\\([^`\n]+\\)`$" text)
       (match-string 1 text)))

(defun claude-code-ide-transcript-document-original-task (text)
  "Return the original first prompt that the handover document TEXT holds, or nil.
The prompt is the block quote of the \"Original task\" part.  A part
without a block quote (the original task was not found) gives nil."
  (when (and (stringp text)
             (string-match "^### Original task.*\n\n" text))
    (let* ((start (match-end 0))
           (end (if (string-match "^#\\{2,3\\} " text start) (match-beginning 0) (length text)))
           (quoted (delq nil (mapcar (lambda (line)
                                       (cond ((string-prefix-p "> " line) (substring line 2))
                                             ((string= ">" line) "")))
                                     (split-string (substring text start end) "\n"))))
           (prompt (string-trim (string-join quoted "\n"))))
      (unless (string-empty-p prompt)
        prompt))))

;;; Rendering

(defun claude-code-ide-transcript--quote (text)
  "Return TEXT as a Markdown block quote."
  (mapconcat (lambda (line) (if (string-empty-p line) ">" (concat "> " line)))
             (split-string (string-trim-right text) "\n")
             "\n"))

(defun claude-code-ide-transcript--cut (text limit)
  "Return TEXT cut to LIMIT characters, with a note when it is cut."
  (if (> (length text) limit)
      (concat (substring text 0 (max 0 limit)) "\n[... cut]")
    text))

(defun claude-code-ide-transcript--code-block (lines empty)
  "Return LINES in a fenced block, or EMPTY when LINES is nil."
  (if lines
      (concat "```\n" (string-join lines "\n") "\n```")
    empty))

(defun claude-code-ide-transcript--describe-leg (leg)
  "Return a short description of LEG for people."
  (string-join
   (delq nil
         (list (format "%s" (or (plist-get leg :provider) 'unknown))
               (format "conversation %s" (or (plist-get leg :native-id) 'unknown))
               (and (plist-get leg :instance-id)
                    (format "instance %s" (plist-get leg :instance-id)))
               (and (plist-get leg :handover-id)
                    (format "started by handover %s%s" (plist-get leg :handover-id)
                            (if (plist-get leg :document-hash)
                                (format " (sha256 %s)" (plist-get leg :document-hash))
                              "")))))
   ", "))

(defun claude-code-ide-transcript--render-header (id source legs target time worktree summary-file)
  "Return the header part of the handover document ID.
SOURCE is the source leg, LEGS all legs, TARGET the target provider,
TIME the time string, WORKTREE the worktree and SUMMARY-FILE the state
summary file of the target."
  (concat
   (format claude-code-ide-transcript--marker-format id) "\n"
   "# Handover document\n\n"
   (format "- Handover ID: %s\n" id)
   (format "- Source: %s\n" (claude-code-ide-transcript--describe-leg source))
   (format "- Target provider: %s\n" (or target 'unknown))
   (format "- Time: %s\n" time)
   (format "- Worktree: %s\n" (or worktree 'unknown))
   (format "- State summary file: `%s`\n" summary-file)
   (if (cdr legs)
       (concat "- Legs of the chain, oldest first:\n"
               (mapconcat (lambda (leg)
                            (format "  - %s" (claude-code-ide-transcript--describe-leg leg)))
                           legs "\n"))
     "- Legs of the chain: this is the first handover.")))

(defun claude-code-ide-transcript--render-workspace (state)
  "Return the workspace part for the workspace STATE plist."
  (if (not (plist-get state :git))
      (format "## Workspace state\n\n%s is not in a Git working tree."
              (or (plist-get state :worktree) "The worktree"))
    (let ((head (plist-get state :head)))
      (string-join
       (list
        "## Workspace state"
        (concat
         (format "- Branch: %s\n" (plist-get state :branch))
         (format "- HEAD: %s%s" head
                 (if (stringp head) (format " %s" (plist-get state :head-subject)) "")))
        (concat "### git status --porcelain\n\n"
                (claude-code-ide-transcript--code-block (plist-get state :status) "Clean."))
        (if (plist-get state :since)
            (concat (format "### Diff stat since %s (the start of the source)\n\n"
                            (plist-get state :since))
                    (claude-code-ide-transcript--code-block (plist-get state :diff-stat)
                                                            "No changes."))
          "### Diff stat since the start of the source\n\nThe start commit is unknown.")
        (concat "### Untracked files\n\n"
                (claude-code-ide-transcript--code-block (plist-get state :untracked) "None."))
        (concat "### git log --oneline -n 20\n\n"
                (claude-code-ide-transcript--code-block (plist-get state :log) "No commits.")))
       "\n\n"))))

(defun claude-code-ide-transcript--turn-heading (turn leg-number provider)
  "Return the heading text of TURN of leg LEG-NUMBER of PROVIDER."
  (format "%s, leg %d (%s)%s"
          (if (eq (plist-get turn :role) 'user) "User" "Assistant")
          leg-number (or provider 'unknown)
          (if (plist-get turn :time) (format ", %s" (plist-get turn :time)) "")))

(defun claude-code-ide-transcript--render-turn (turn leg-number provider &optional reference)
  "Return TURN of leg LEG-NUMBER of PROVIDER as text.
With REFERENCE, a string, the text of the turn is not repeated: the
turn names REFERENCE, where the text already is."
  (let ((text (plist-get turn :text))
        (tools (plist-get turn :tools)))
    (concat
     "#### " (claude-code-ide-transcript--turn-heading turn leg-number provider) "\n\n"
     (cond
      (reference (format "(%s.)" reference))
      (text (claude-code-ide-transcript--quote
             (claude-code-ide-transcript--cut text claude-code-ide-transcript-turn-limit)))
      (t ""))
     (if (and (or reference text) tools) "\n\n" "")
     (mapconcat (lambda (line) (concat "- Tool " line)) tools "\n"))))

(defun claude-code-ide-transcript--fit (heading entries budget note-format)
  "Return (TEXT . KEPT): HEADING and the newest ENTRIES that fit in BUDGET.
BUDGET is in characters.  ENTRIES are strings, oldest first, and KEPT
is the number of the newest entries in TEXT.  When entries are left
out, a note made with NOTE-FORMAT and their count follows the heading.
Return nil when not even the heading and the note fit."
  (let ((all (string-join (cons heading entries) "\n\n")))
    (if (<= (length all) budget)
        (cons all (length entries))
      ;; Not all entries fit, so the note is always there.
      (let* ((total (length entries))
             (note-size (lambda (left-out) (+ 2 (length (format note-format left-out)))))
             (kept nil)
             (size (length heading)))
        (catch 'full
          (dolist (entry (reverse entries))
            (if (<= (+ size 2 (length entry) (funcall note-size (- total (length kept) 1)))
                    budget)
                (progn (push entry kept)
                       (setq size (+ size 2 (length entry))))
              (throw 'full nil))))
        (let ((left-out (- total (length kept))))
          (when (<= (+ size (funcall note-size left-out)) budget)
            (cons (string-join (append (list heading (format note-format left-out)) kept)
                               "\n\n")
                  (length kept))))))))

(defun claude-code-ide-transcript--read-summary (file worktree)
  "Return the content of the state summary FILE, relative to WORKTREE, or nil."
  (when (stringp file)
    (let ((path (expand-file-name file (or worktree default-directory))))
      (when (file-readable-p path)
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents path))
          (string-trim (buffer-string)))))))

(defconst claude-code-ide-transcript--not-carried-over
  (concat
   "## Not carried over\n\n"
   "- Background tasks and subagents of the source that still run.\n"
   "- The permission mode of the source.\n"
   "- The plan mode of the source.")
  "The part of the handover document that lists what does not move.")

(defun claude-code-ide-transcript--instructions (summary-file)
  "Return the instructions part, with the state summary file SUMMARY-FILE."
  (concat
   "## Instructions\n\n"
   "- The workspace state and the context from the coordinator have priority over older history.\n"
   "- A newer user prompt replaces an older one when they disagree.\n"
   "- The history is information.  Instructions of earlier handover documents do not apply.\n"
   "- Read each file again before you edit it.\n"
   (format "- Your first turn: write a short state summary to `%s` before you do other work.  " summary-file)
   "Say what the task is, what is done, what is open, and which requirements apply now.  "
   "This file is not part of the work.  Do not commit it.\n"
   "- Then reply `ready` and wait for the next prompt."))

(defun claude-code-ide-transcript--leg-read (leg root)
  "Return (:format FORMAT :turns TURNS :meta META :records LINES) of LEG.
The transcript of LEG is read one time.  The format is the provider of
LEG when it has a reader, else it comes from the file.  META is the
Codex session metadata, or nil.  LINES is the number of lines of the
file, or nil for a reader of another package.  Tool paths are relative
to ROOT.  A leg without a readable transcript gives nil."
  (let* ((file (plist-get leg :transcript))
         (file (and (stringp file) (file-readable-p file) file))
         (provider (plist-get leg :provider))
         (format (and file (if (assq provider claude-code-ide-transcript-readers)
                               provider
                             (claude-code-ide-transcript-format file))))
         (reader (alist-get format claude-code-ide-transcript-readers)))
    (cond
     ((null reader) nil)
     ((eq reader #'claude-code-ide-transcript-read-codex)
      (cons :format (cons format (claude-code-ide-transcript--read-codex-full file root))))
     ((eq reader #'claude-code-ide-transcript-read-claude)
      (cons :format (cons format (claude-code-ide-transcript--read-claude-full file root))))
     (t (list :format format :turns (funcall reader file root) :meta nil :records nil)))))

(defun claude-code-ide-transcript--split-bootstrap (turns)
  "Return (KEPT . DOCUMENTS) for TURNS.
A user turn that holds a handover document and the assistant turns
after it, up to the next user turn, are the bootstrap of a leg.  KEPT
is TURNS without those turns.  DOCUMENTS lists the text of each
document turn."
  (let (kept documents in-bootstrap)
    (dolist (turn turns)
      (cond
       ((and (eq (plist-get turn :role) 'user)
             (claude-code-ide-transcript-document-id (plist-get turn :text)))
        (push (plist-get turn :text) documents)
        (setq in-bootstrap t))
       ((eq (plist-get turn :role) 'user)
        (setq in-bootstrap nil)
        (push turn kept))
       ((not in-bootstrap) (push turn kept))))
    (cons (nreverse kept) (nreverse documents))))

(defun claude-code-ide-transcript--first-user-turn (turns)
  "Return the first user turn of TURNS, or nil."
  (cl-find 'user turns :key (lambda (turn) (plist-get turn :role))))

(defun claude-code-ide-transcript--source-start-commit (leg data worktree)
  "Return the commit where the source LEG started, or nil.
DATA is the leg data of the source and WORKTREE the working tree.  The
commit is the :start-commit of LEG, else the commit of the Codex
session metadata of the read, else the last commit before the first
turn."
  (or (plist-get leg :start-commit)
      (plist-get (plist-get data :meta) :commit)
      (and worktree
           (when-let* ((start (plist-get (car (plist-get data :all)) :time)))
             (claude-code-ide-transcript-commit-at worktree start)))))

(defun claude-code-ide-transcript--quote-cut (text limit)
  "Return TEXT as a block quote of at most LIMIT characters, or nil.
The length counts the \"> \" of each line.  A quote that is too long
keeps its start, and its last line is \"> [... cut]\".  nil means that
not even that line fits."
  (let ((full (claude-code-ide-transcript--quote text))
        (note "> [... cut]"))
    (cond
     ((<= (length full) limit) full)
     ((< limit (length note)) nil)
     (t
      ;; The cut is in the quoted text, so each kept line keeps its "> ".
      (let ((kept (string-trim-right
                   (substring full 0 (max 0 (- limit (length note) 1)))
                   "\n")))
        (if (string-empty-p kept) note (concat kept "\n" note)))))))

(defun claude-code-ide-transcript--render-summary (file summary budget)
  "Return the state summary part for FILE with the text SUMMARY, or nil.
SUMMARY is nil when FILE does not exist.  The part is at most BUDGET
characters: a long SUMMARY is cut at the end.  nil means that not even
the heading and the cut note fit."
  (let* ((heading (format "### State summary of the previous target (%s)\n\n" file))
         (body (if summary
                   (claude-code-ide-transcript--quote-cut summary (- budget (length heading)))
                 "The file does not exist.")))
    (and body
         (<= (+ (length heading) (length body)) budget)
         (concat heading body))))

;;; References to the source sessions

(defcustom claude-code-ide-handover-session-server "claude-sessions"
  "Name of the MCP server that reads past sessions, or nil.
When the target of a handover has an MCP server of this name, the
handover document tells the target to read the source sessions with
its tools.  nil turns these references off; the document then names
only the transcript files."
  :type '(choice (string :tag "Server name") (const :tag "Off" nil))
  :group 'claude-code-ide-transcript)

(defcustom claude-code-ide-handover-session-server-providers '(claude)
  "Providers whose sessions the session server reads.
The session server is `claude-code-ide-handover-session-server'.
The server named \"claude-sessions\" reads Claude Code sessions only.
For a leg of another provider, the document names the transcript file."
  :type '(repeat symbol)
  :group 'claude-code-ide-transcript)

(defconst claude-code-ide-transcript--session-tools
  '(get_session_outline get_messages)
  "Tools of the session server that the handover document names.")

(defun claude-code-ide-transcript--read-json-file (file)
  "Return the JSON object in FILE as a hash table with string keys, or nil.
A missing or broken file gives nil."
  (when (and (stringp file) (file-readable-p file))
    (condition-case nil
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (let ((value (json-parse-buffer :object-type 'hash-table :null-object nil
                                          :false-object nil)))
            (and (hash-table-p value) value)))
      (error nil))))

(defun claude-code-ide-transcript--json-get (object &rest keys)
  "Return the value at the string KEYS in the nested hash tables of OBJECT."
  (while (and keys (hash-table-p object))
    (setq object (gethash (pop keys) object)))
  (and (null keys) object))

(defun claude-code-ide-transcript--has-server-p (servers name)
  "Return non-nil when the hash table SERVERS has the server NAME."
  (and (hash-table-p servers) (hash-table-p (gethash name servers)) t))

(defun claude-code-ide-transcript--claude-config-file ()
  "Return the global configuration file of Claude Code (.claude.json).
It is in CLAUDE_CONFIG_DIR when that is set, else in HOME."
  (expand-file-name ".claude.json" (or (getenv "CLAUDE_CONFIG_DIR") (getenv "HOME") "~")))

(defun claude-code-ide-transcript--claude-project-entry (config worktree)
  "Return the project entry of WORKTREE in the Claude Code CONFIG, or nil."
  (let ((projects (claude-code-ide-transcript--json-get config "projects")))
    (when (and worktree (hash-table-p projects))
      (let ((dir (directory-file-name (expand-file-name worktree))))
        (or (gethash dir projects)
            (gethash (file-name-as-directory dir) projects)
            (gethash (directory-file-name (file-truename dir)) projects))))))

(defun claude-code-ide-transcript--claude-server-p (name worktree)
  "Return non-nil when Claude Code in WORKTREE has the MCP server NAME.
The server can be in the user scope (mcpServers of .claude.json), in
the local scope (the project entry of WORKTREE in .claude.json), or in
the project scope (WORKTREE/.mcp.json, unless the project entry
disables it).  The files are only read."
  (let* ((config (claude-code-ide-transcript--read-json-file
                  (claude-code-ide-transcript--claude-config-file)))
         (project (claude-code-ide-transcript--claude-project-entry config worktree))
         (shared (and worktree
                      (claude-code-ide-transcript--read-json-file
                       (expand-file-name ".mcp.json" worktree)))))
    (or (claude-code-ide-transcript--has-server-p
         (claude-code-ide-transcript--json-get config "mcpServers") name)
        (claude-code-ide-transcript--has-server-p
         (claude-code-ide-transcript--json-get project "mcpServers") name)
        (and (claude-code-ide-transcript--has-server-p
              (claude-code-ide-transcript--json-get shared "mcpServers") name)
             (not (member name (append (claude-code-ide-transcript--json-get
                                        project "disabledMcpjsonServers")
                                       nil)))))))

(defun claude-code-ide-transcript--codex-config-file ()
  "Return the configuration file of Codex.
It is config.toml in CODEX_HOME when that is set, else in HOME/.codex."
  (expand-file-name "config.toml"
                    (or (getenv "CODEX_HOME")
                        (expand-file-name ".codex" (or (getenv "HOME") "~")))))

(defun claude-code-ide-transcript--codex-server-p (name)
  "Return non-nil when the Codex configuration has the MCP server NAME.
That is a table [mcp_servers.NAME] (the name can be quoted) without
`enabled = false', or a key mcp_servers.NAME = ....  The file is only
read, line by line, without a full TOML parser."
  (let ((file (claude-code-ide-transcript--codex-config-file))
        (key (concat "mcp_servers\\.\\(?:" (regexp-quote name)
                     "\\|\"" (regexp-quote name) "\"\\|'" (regexp-quote name) "'\\)")))
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8)
              (case-fold-search nil))
          (insert-file-contents file)
          (goto-char (point-min))
          (cond
           ((re-search-forward (concat "^[ \t]*\\[[ \t]*" key "[ \t]*\\][ \t]*\\(?:#.*\\)?$") nil t)
            ;; The table ends at the next table header.
            (let ((end (save-excursion
                         (if (re-search-forward "^[ \t]*\\[" nil t) (match-beginning 0) (point-max)))))
              (not (re-search-forward "^[ \t]*enabled[ \t]*=[ \t]*false\\b" end t))))
           ((re-search-forward (concat "^[ \t]*" key "[ \t]*=") nil t) t)))))))

(defun claude-code-ide-transcript-session-server-p (provider &optional worktree)
  "Return non-nil when the PROVIDER configuration has the session server.
The server is `claude-code-ide-handover-session-server'.  PROVIDER is
`claude' or `codex'; WORKTREE is the folder where it runs.  Another
provider, or a nil server name, gives nil.  The configuration files
are only read, and a missing or broken file gives nil."
  (let ((name claude-code-ide-handover-session-server))
    (and (stringp name) (not (string-empty-p name))
         (pcase provider
           ('claude (claude-code-ide-transcript--claude-server-p name worktree))
           ('codex (claude-code-ide-transcript--codex-server-p name))))))

(defun claude-code-ide-transcript-session-tool (provider tool)
  "Return the name that the target PROVIDER gives TOOL of the session server.
Claude Code uses mcp__SERVER__TOOL.  Codex changes the hyphens of the
server name to underscores.  Another provider gives nil."
  (let ((server claude-code-ide-handover-session-server))
    (pcase provider
      ('claude (format "mcp__%s__%s" server tool))
      ('codex (format "mcp__%s__%s" (string-replace "-" "_" server) tool)))))

(defun claude-code-ide-transcript--leg-native-id (leg data)
  "Return the native conversation ID of LEG with its leg DATA, or nil.
It is the :native-id of LEG, else the ID in the Codex metadata, else
the name of a CC transcript file."
  (or (plist-get leg :native-id)
      (plist-get (plist-get data :meta) :id)
      (and (eq (plist-get data :format) 'claude)
           (stringp (plist-get leg :transcript))
           (file-name-base (plist-get leg :transcript)))))

(defun claude-code-ide-transcript--leg-uses-server-p (leg server)
  "Return non-nil when the target reads LEG with the session server.
SERVER is non-nil when the target has the server."
  (and server
       (memq (plist-get leg :provider) claude-code-ide-handover-session-server-providers)))

(defconst claude-code-ide-transcript--format-names
  '((claude . "Claude Code JSONL: one JSON record on each line")
    (codex . "Codex rollout JSONL: one JSON record on each line"))
  "Names of the transcript formats for people.")

(defun claude-code-ide-transcript--render-leg-reference (data source-p server)
  "Return the reference entry of the leg DATA.
SOURCE-P is non-nil for the source leg.  SERVER is non-nil when the
target has the session server."
  (let* ((leg (plist-get data :leg))
         (all (plist-get data :all))
         (native (claude-code-ide-transcript--leg-native-id leg data))
         (file (plist-get leg :transcript))
         (format (plist-get data :format))
         (records (plist-get data :records)))
    (string-join
     (delq nil
           (list
            (format "### Leg %d: %s%s" (plist-get data :number)
                    (or (plist-get leg :provider) 'unknown)
                    (if source-p " (the source: this leg just ended)" ""))
            ""
            (format "- Conversation ID: %s" (or native 'unknown))
            (format "- Transcript: %s" (if file (format "`%s`" (expand-file-name file)) "unknown"))
            (and format (format "- Format: %s" (alist-get format claude-code-ide-transcript--format-names)))
            (format "- Started: %s" (or (plist-get (car all) :time) 'unknown))
            (format "- Ended: %s%s" (or (plist-get (car (last all)) :time) 'unknown)
                    (if records
                        (format ", at record %d (line %d of the file).  Later records are not part of this chain."
                                records records)
                      "."))
            (format "- Read it with: %s"
                    (if (and native (claude-code-ide-transcript--leg-uses-server-p leg server))
                        (format "the %s tools (conversation_id %s), or the file"
                                claude-code-ide-handover-session-server native)
                      "the file"))))
     "\n")))

(defun claude-code-ide-transcript--render-server-instructions (target)
  "Return the instructions to read the legs with the session server of TARGET."
  (let ((outline (claude-code-ide-transcript-session-tool target 'get_session_outline))
        (messages (claude-code-ide-transcript-session-tool target 'get_messages)))
    (concat
     (format "The user asks you to read the source sessions with the %s tools when you need a detail.  "
             claude-code-ide-handover-session-server)
     "This is the explicit request of the user for these tools.\n\n"
     (format "1. Call `%s` with the conversation ID of the leg, in pages of 100: " outline)
     "`limit` 100, then `start_position` set to `next_position` of the page before.\n"
     (format "2. Call `%s` with the conversation ID and only the `positions` that you need.\n" messages)
     "3. Do not fetch a whole session at once: always give `positions`.\n"
     "4. Use the end time of the leg: messages after it are not part of this chain.")))

(defun claude-code-ide-transcript--render-file-instructions (formats)
  "Return the instructions to read the transcript files of FORMATS."
  (concat
   "Each transcript file can be very large (hundreds of megabytes).  "
   "Never read a whole file.  Read only parts, with commands like these "
   "(FILE is the transcript, N the end record of the leg):\n\n"
   "- Find a word, with a short context: "
   "`grep -n -o '.\\{0,100\\}WORD.\\{0,100\\}' FILE | head -n 20`\n"
   "- The last records of a leg: `head -n N FILE | tail -n 40 | cut -c1-400`"
   (if (memq 'claude formats)
       (concat
        "\n- Claude Code: prompts and replies are the records with `\"type\":\"user\"` and "
        "`\"type\":\"assistant\"`, with the text in `message.content`.  With jq: "
        "`head -n N FILE | tail -n 200 | jq -c 'select(.type==\"user\" or .type==\"assistant\") "
        "| [.timestamp, .type, (.message.content | tostring | .[0:300])]'`")
     "")
   (if (memq 'codex formats)
       (concat
        "\n- Codex: the turns are the records with `\"type\":\"event_msg\"` and "
        "`payload.type` `item_completed`; `payload.item.type` is `UserMessage`, `AgentMessage`, "
        "`CommandExecution` or `FileChange`.  With jq: "
        "`head -n N FILE | tail -n 400 | jq -c 'select(.payload.type==\"item_completed\") "
        "| [.timestamp, .payload.item.type, (.payload.item | tostring | .[0:300])]'`")
     "")))

(defun claude-code-ide-transcript--render-references (leg-data server target)
  "Return the \"Source sessions\" part for LEG-DATA, oldest first.
SERVER is non-nil when the TARGET provider has the session server.
The last leg is the source."
  (let* ((source (car (last leg-data)))
         (via-server (cl-some (lambda (data)
                                (and (claude-code-ide-transcript--leg-uses-server-p
                                      (plist-get data :leg) server)
                                     (claude-code-ide-transcript--leg-native-id
                                      (plist-get data :leg) data)))
                              leg-data))
         (formats (delete-dups (delq nil (mapcar (lambda (data) (plist-get data :format))
                                                 leg-data)))))
    (string-join
     (append
      (list "## Source sessions"
            (concat "The history below is a short extract.  "
                    "The source sessions have all details: read them when you need a detail."))
      (and via-server (list (claude-code-ide-transcript--render-server-instructions target)))
      (list (concat (if via-server "Without these tools, read the files.  " "")
                    (claude-code-ide-transcript--render-file-instructions formats)))
      (mapcar (lambda (data)
                (claude-code-ide-transcript--render-leg-reference
                 data (eq data source) server))
              leg-data))
     "\n\n")))

(cl-defun claude-code-ide-transcript-handover-document
    (&key source chain context budget handover-id target-provider summary-file time
          (session-server 'auto))
  "Return the text of a handover document, as plan section 4.7 describes.
SOURCE is the source: an instance descriptor, or a leg plist.  CHAIN
is the list of the earlier legs of the chain, oldest first; each is a
leg plist or a descriptor (see docs/handover-document.md).  A leg of
CHAIN that is the conversation of SOURCE gives SOURCE its missing
values, such as its state summary file.  CONTEXT is text from the
coordinator, or nil.  BUDGET is the size budget in characters, or nil
for `claude-code-ide-transcript-budget'.

These keys are optional: HANDOVER-ID (a new ID when nil),
TARGET-PROVIDER (a provider name, or nil for unknown), SUMMARY-FILE
\(the file for the state summary of the target; nil gives a file in
the worktree after `claude-code-ide-transcript-summary-file-format'),
TIME (a Lisp time, nil for now) and SESSION-SERVER.  SESSION-SERVER
says whether the target has the server
`claude-code-ide-handover-session-server': t, nil, or `auto' (the
default) to read the configuration of TARGET-PROVIDER with
`claude-code-ide-transcript-session-server-p'.  With the server, the
\"Source sessions\" part tells the target to read the legs of the
providers in `claude-code-ide-handover-session-server-providers' with
its tools.  The part always names the transcript files."
  (let* ((source-leg (claude-code-ide-transcript--leg source))
         (earlier (mapcar #'claude-code-ide-transcript--leg chain))
         (same (cl-find-if (lambda (leg) (claude-code-ide-transcript--same-leg-p leg source-leg))
                           earlier))
         (source-leg (if same (claude-code-ide-transcript--merge-legs source-leg same) source-leg))
         (earlier (remq same earlier))
         (legs (append earlier (list source-leg)))
         (worktree (or (plist-get source-leg :worktree)
                       (cl-some (lambda (leg) (plist-get leg :worktree)) (reverse earlier))))
         (id (or handover-id (claude-code-ide-instance-new-id)))
         (summary-file (or summary-file
                           (let ((name (format claude-code-ide-transcript-summary-file-format id)))
                             (if worktree (expand-file-name name worktree) name))))
         (budget (or budget claude-code-ide-transcript-budget))
         ;; For each leg: the result of one read of its transcript, all
         ;; its turns, the turns without the bootstrap, and the
         ;; handover documents that it received.
         (leg-data (cl-loop for leg in legs
                            for number from 1
                            collect (let* ((read (claude-code-ide-transcript--leg-read leg worktree))
                                           (all (plist-get read :turns))
                                           (split (claude-code-ide-transcript--split-bootstrap all)))
                                      (list :leg leg :number number :all all
                                            :meta (plist-get read :meta)
                                            :format (plist-get read :format)
                                            :records (plist-get read :records)
                                            :turns (car split) :documents (cdr split)))))
         (source-data (car (last leg-data)))
         ;; Whether the target can read sessions with the session server.
         (server (and (stringp claude-code-ide-handover-session-server)
                      (claude-code-ide-transcript-session-tool target-provider 'get_messages)
                      (if (eq session-server 'auto)
                          (claude-code-ide-transcript-session-server-p target-provider worktree)
                        session-server)
                      t))
         ;; The state summary of the previous target is that of the
         ;; source, when a handover started the source.
         (source-summary-file
          (or (plist-get source-leg :summary-file)
              (cl-some #'claude-code-ide-transcript-document-summary-file
                       (plist-get source-data :documents))))
         ;; The original first prompt is the first prompt of the first
         ;; leg.  When a handover document started that leg, it is the
         ;; original task in that document.
         (first-raw (claude-code-ide-transcript--first-user-turn
                     (plist-get (car leg-data) :all)))
         (first-document-p (claude-code-ide-transcript-document-id (plist-get first-raw :text)))
         (first-turn (and first-raw (not first-document-p) first-raw))
         (first-prompt (if first-turn
                           (plist-get first-turn :text)
                         (claude-code-ide-transcript-document-original-task
                          (plist-get first-raw :text))))
         (state (claude-code-ide-transcript-workspace-state
                 worktree (claude-code-ide-transcript--source-start-commit
                           source-leg source-data worktree)))
         (fixed-before
          (delq nil
                (list (claude-code-ide-transcript--render-header
                       id source-leg legs target-provider
                       (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t)
                       (or (plist-get state :worktree) worktree) summary-file)
                      (claude-code-ide-transcript--render-workspace state)
                      (and context (not (string-empty-p (string-trim context)))
                           (concat "## Context from the coordinator\n\n" (string-trim context)))
                      (claude-code-ide-transcript--render-references
                       leg-data server target-provider)
                      "## History of the chain"
                      (concat "### Original task (the first user prompt of the chain; "
                              "it can be out of date)\n\n"
                              (if first-prompt
                                  (claude-code-ide-transcript--quote first-prompt)
                                "Not found in the transcripts.")))))
         (fixed-after (list claude-code-ide-transcript--not-carried-over
                            (claude-code-ide-transcript--instructions summary-file)))
         ;; Each variable part costs its length and a separator of 2.
         ;; The final newline costs 1.
         (remaining (- budget 1 (length (string-join (append fixed-before fixed-after) "\n\n"))))
         ;; Each user prompt has a number: P1 is the original task.
         (numbers (make-hash-table :test 'eq))
         (prompt-entries nil)
         (variable nil))
    ;; The state summary of the previous target.
    (when-let* ((part (and source-summary-file
                           (claude-code-ide-transcript--render-summary
                            source-summary-file
                            (claude-code-ide-transcript--read-summary source-summary-file worktree)
                            (- remaining 2)))))
      (push part variable)
      (setq remaining (- remaining 2 (length part))))
    ;; Every user prompt of the chain, oldest first.  The original
    ;; task is not repeated.  Without an original task, the first
    ;; listed prompt is P1.
    (let ((count (if first-prompt 1 0)))
      (when first-turn
        (puthash first-turn 1 numbers))
      (dolist (data leg-data)
        (dolist (turn (plist-get data :turns))
          (when (and (eq (plist-get turn :role) 'user) (not (eq turn first-turn)))
            (setq count (1+ count))
            (puthash turn count numbers)
            (push (concat (format "- P%d: %s\n\n" count
                                  (claude-code-ide-transcript--turn-heading
                                   turn (plist-get data :number)
                                   (plist-get (plist-get data :leg) :provider)))
                          (claude-code-ide-transcript--quote
                           (claude-code-ide-transcript--cut
                            (plist-get turn :text) claude-code-ide-transcript-prompt-limit)))
                  prompt-entries)))))
    (setq prompt-entries (nreverse prompt-entries))
    (let* ((turn-heading "### Latest turns, oldest first")
           ;; A prompt that is already in the document is named in the
           ;; latest turns, not repeated: P1, and the prompts with a
           ;; number above LISTED-ABOVE.
           (render
            (lambda (turn data listed-above)
              (let ((number (gethash turn numbers)))
                (claude-code-ide-transcript--render-turn
                 turn (plist-get data :number)
                 (plist-get (plist-get data :leg) :provider)
                 (cond
                  ((null number) nil)
                  ((eq turn first-turn) "P1, the original task above")
                  ((> number listed-above)
                   (format "P%d in the list of user prompts above" number)))))))
           ;; Each turn is rendered one time, as if every prompt were in
           ;; the list.  This also measures what the turns need.
           (items (cl-loop for data in leg-data
                           append (mapcar (lambda (turn)
                                            (list turn data (funcall render turn data 0)))
                                          (plist-get data :turns))))
           (turns-need (+ 2 (length turn-heading)
                          (apply #'+ (mapcar (lambda (item) (+ 2 (length (nth 2 item))))
                                             items))))
           ;; The list of prompts gets half of the rest of the budget,
           ;; or more when the latest turns need less.
           (prompt-budget (max (/ (- remaining 2) 2) (- remaining 2 turns-need)))
           (fit (and prompt-entries
                     (claude-code-ide-transcript--fit
                      (if first-prompt
                          "### User prompts of the chain, oldest first (P1 is the original task)"
                        "### User prompts of the chain, oldest first")
                      prompt-entries prompt-budget
                      "(%d earlier prompts are left out because of the size budget.)")))
           ;; The prompts with a number above this one are in the list.
           (listed-above (+ (if first-prompt 1 0)
                            (- (length prompt-entries) (or (cdr fit) 0)))))
      (when fit
        (push (car fit) variable)
        (setq remaining (- remaining 2 (length (car fit)))))
      ;; Only the turns of the prompts that the list left out are
      ;; rendered again, with their text.
      (let* ((entries (mapcar (lambda (item)
                                (let ((number (gethash (car item) numbers)))
                                  (if (and number (not (eq (car item) first-turn))
                                           (<= number listed-above))
                                      (funcall render (car item) (nth 1 item) listed-above)
                                    (nth 2 item))))
                              items))
             (fit (and entries
                       (claude-code-ide-transcript--fit
                        turn-heading entries (- remaining 2)
                        "(%d older turns are left out because of the size budget.)"))))
        (when fit
          (push (car fit) variable))))
    (concat (string-join (append fixed-before (nreverse variable) fixed-after) "\n\n")
            "\n")))

(provide 'claude-code-ide-transcript)

;;; claude-code-ide-transcript.el ends here
