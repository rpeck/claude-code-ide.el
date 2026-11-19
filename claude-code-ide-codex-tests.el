;;; claude-code-ide-codex-tests.el --- Tests for the Codex provider  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the `codex' provider: the command lines, the TOML quoting,
;; the MCP config, the shell environment policy, the approvals, the
;; environment, `codex queue', the native ID, the exit messages and the
;; dialog scan.  The file is loaded by claude-code-ide-tests.el, after
;; its mocks.  All projects, conversation IDs and header values are
;; synthetic.  No test runs Codex: the process tests run small shell
;; scripts in its place.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-codex)
(require 'claude-code-ide-provider-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")

;;; Helpers

(defconst claude-code-ide-codex-tests--token "cci-test-header-value"
  "Value of the header that the stub advice adds.")

(defvar claude-code-ide-codex-tests--exclude nil
  "What the stubbed reader of the user's exclude list returns.")

(defun claude-code-ide-codex-tests--add-header (config)
  "Add a token header to CONFIG, as the advice of rp-emacs-mcp does."
  (let ((server (alist-get 'emacs-tools (alist-get 'mcpServers config))))
    (if (not server)
        config
      `((mcpServers
         . ((emacs-tools
             . ,(append server
                        `((headers
                           . ((X-Emacs-MCP-Token . ,claude-code-ide-codex-tests--token))))))))))))

(defun claude-code-ide-codex-tests--never-auto-allow (names)
  "Remove emacs_eval from NAMES, as the advice of rp-emacs-mcp does."
  (cl-remove-if (lambda (name) (string-suffix-p "emacs_eval" name)) names))

(defmacro claude-code-ide-codex-tests--with-mcp (&rest body)
  "Run BODY with a mocked MCP server on port 40001 and two tools.
The advice of rp-emacs-mcp is in place: a header and no automatic
approval of emacs_eval.  The user excludes no variable, no status hooks
are bound, and no Codex process runs."
  (declare (indent 0))
  `(let ((claude-code-ide-mcp-server-tools
          (list (list :function #'ignore :name "claude-code-ide-mcp-project-info"
                      :description "cci-test")
                (list :function #'ignore :name "emacs_eval" :description "cci-test")))
         (claude-code-ide-mcp-allowed-tools 'auto)
         (claude-code-ide-system-prompt nil)
         (claude-code-ide-cli-extra-flags "--cc-only")
         (claude-code-ide-codex-cli-path "codex")
         (claude-code-ide-codex-extra-flags "")
         (claude-code-ide-codex-no-alt-screen t)
         (claude-code-ide-codex-skip-update-check t)
         (claude-code-ide-codex-remove-openai-api-key t)
         (claude-code-ide-codex--warned-plain-headers nil)
         (claude-code-ide-codex-tests--exclude nil))
     (advice-add 'claude-code-ide-mcp-server-get-config
                 :filter-return #'claude-code-ide-codex-tests--add-header)
     (advice-add 'claude-code-ide-mcp-server-get-tool-names
                 :filter-return #'claude-code-ide-codex-tests--never-auto-allow)
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) (lambda () 40001))
                   ((symbol-function 'claude-code-ide-mcp-server-get-port) (lambda () 40001))
                   ((symbol-function 'claude-code-ide-codex--read-exclude)
                    (lambda (_directory) claude-code-ide-codex-tests--exclude))
                   ((symbol-function 'claude-code-ide-codex-status-hook-args) nil)
                   ((symbol-function 'claude-code-ide-codex-status-hook-env) nil)
                   ((symbol-function 'claude-code-ide-codex-events-map-event) nil))
           ,@body)
       (advice-remove 'claude-code-ide-mcp-server-get-config
                      #'claude-code-ide-codex-tests--add-header)
       (advice-remove 'claude-code-ide-mcp-server-get-tool-names
                      #'claude-code-ide-codex-tests--never-auto-allow))))

(defun claude-code-ide-codex-tests--instance (&optional native-id)
  "Return a Codex descriptor with an MCP session \"cci-test-sess\".
NATIVE-ID is its native ID, or `unknown'.  Its generation is 1."
  (claude-code-ide-instance-create
   :id "cci-test-inst"
   :provider 'codex
   :native-id (or native-id 'unknown)
   :project-root "/tmp/cci-test-codex/proj/"
   :generation 1
   :session (claude-code-ide-tests--make-session
             "/tmp/cci-test-codex/proj/" :session-id "cci-test-sess")))

(defun claude-code-ide-codex-tests--words (result)
  "Return the words of the :command of RESULT, as a shell splits them."
  (claude-code-ide--split-command-line (plist-get result :command)))

(defun claude-code-ide-codex-tests--variable ()
  "Return the name of the variable of the test header."
  (claude-code-ide-codex--header-variable "X-Emacs-MCP-Token"))

(defun claude-code-ide-codex-tests--common-words ()
  "Return the words that each command has right after its subcommand."
  (list "--no-daemon" "--no-alt-screen"
        "-c" "check_for_update_on_startup=false"
        "-c" (concat "developer_instructions=\"" claude-code-ide-codex--emacs-prompt "\"")))

(defun claude-code-ide-codex-tests--mcp-words ()
  "Return the MCP words of a command, with the header of the stub advice."
  (let ((variable (claude-code-ide-codex-tests--variable)))
    (list "-c" "mcp_servers.emacs_tools.url=\"http://localhost:40001/mcp/cci-test-sess\""
          "-c" (format "mcp_servers.emacs_tools.env_http_headers={\"X-Emacs-MCP-Token\"=\"%s\"}"
                       variable)
          "-c" (format "shell_environment_policy.exclude=[\"%s\"]" variable)
          "-c" "mcp_servers.emacs_tools.default_tools_approval_mode=\"prompt\""
          "-c" "mcp_servers.emacs_tools.tools.claude-code-ide-mcp-project-info.approval_mode=\"approve\"")))

(defun claude-code-ide-codex-tests--spec (&rest args)
  "Return a Codex start spec for the test project, with ARGS."
  ;; The first of two equal keywords wins, so ARGS come first.  The
  ;; spec's extra flags are Claude Code flags, which Codex never gets.
  (apply #'claude-code-ide-start-spec-create
         (append args (list :directory "/tmp/cci-test-codex/proj/"
                            :provider 'codex :extra-flags "--cc-only"))))

(defun claude-code-ide-codex-tests--screen (text)
  "Return a new buffer that holds the terminal screen TEXT."
  (let ((buffer (generate-new-buffer "*cci-test-codex-screen*")))
    (with-current-buffer buffer (insert text))
    buffer))

(defun claude-code-ide-codex-tests--fake-codex (body)
  "Return the path of a new shell script named codex, with BODY.
The script runs in its own temporary folder; $D names that folder."
  (let* ((dir (make-temp-file "cci-test-codex-" t))
         (file (expand-file-name "codex" dir)))
    (with-temp-file file
      (insert "#!/bin/sh\nD=$(dirname \"$0\")\n" body))
    (set-file-modes file #o755)
    file))

(defun claude-code-ide-codex-tests--file-words (file)
  "Return the NUL-separated words of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\0" t)))

(defun claude-code-ide-codex-tests--wait (predicate &optional seconds)
  "Read process output until PREDICATE returns non-nil, at most SECONDS."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

;;; Provider

(ert-deftest claude-code-ide-test-codex-provider-registered ()
  "The codex provider is registered with its prefix and its operations."
  (let ((provider (claude-code-ide-get-provider 'codex)))
    (should (eq provider claude-code-ide-codex--provider))
    (should (equal (claude-code-ide-provider-display-name provider) "Codex"))
    (should (equal (claude-code-ide-provider-buffer-name-prefix provider) "codex"))
    (should (equal (claude-code-ide-provider-capabilities provider)
                   '(detect launch resume fork submit-prompt stop native-id
                            map-event mcp-setup exit-message)))
    ;; The stop of Claude Code fits: it kills the terminal buffer
    (should (eq (claude-code-ide-provider-stop provider) #'claude-code-ide--claude-stop))
    (should (claude-code-ide-provider-unavailable-p
             (claude-code-ide-provider-call provider 'transcript nil 'file)))))

(ert-deftest claude-code-ide-test-codex-detect ()
  "detect finds the CLI with executable-find and reads codex --version."
  (let ((claude-code-ide-codex-cli-path "codex")
        (calls nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &rest _) (and (equal name "codex") "/x/bin/codex")))
              ((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest args)
                 (push (cons program args) calls)
                 (insert "codex-cli 0.164.0\n")
                 0)))
      (should (equal (claude-code-ide-codex--detect)
                     '(:available t :program "codex" :version unknown)))
      (should-not calls)
      (should (equal (claude-code-ide-codex--detect t)
                     '(:available t :program "codex" :version "codex-cli 0.164.0")))
      (should (equal calls '(("/x/bin/codex" "--version")))))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (should (equal (claude-code-ide-codex--detect t)
                     '(:available nil :program "codex" :version unknown))))))

(ert-deftest claude-code-ide-test-codex-exit-messages ()
  "The exit messages name the Codex program."
  (let ((spec (claude-code-ide-codex-tests--spec)))
    (should (string-match-p "\\`Codex CLI not found (exit 127).*'/x/codex'"
                            (claude-code-ide-codex--exit-message 127 spec "/x/codex")))
    (should (string-match-p "\\`Codex CLI '/x/codex' was found but is not executable (exit 126)"
                            (claude-code-ide-codex--exit-message 126 spec "/x/codex")))
    (should (equal (claude-code-ide-codex--exit-message 2 spec "/x/codex")
                   "Codex ('/x/codex') exited with error code 2"))))

;;; TOML quoting

(ert-deftest claude-code-ide-test-codex-toml-string ()
  "TOML basic strings escape quotes, backslashes and control characters."
  (should (equal (claude-code-ide-codex--toml-string "plain text") "\"plain text\""))
  (should (equal (claude-code-ide-codex--toml-string "say \"hi\"") "\"say \\\"hi\\\"\""))
  (should (equal (claude-code-ide-codex--toml-string "a\\b") "\"a\\\\b\""))
  (should (equal (claude-code-ide-codex--toml-string "one\ntwo\tthree\r")
                 "\"one\\ntwo\\tthree\\r\""))
  (should (equal (claude-code-ide-codex--toml-string (string 1 127)) "\"\\u0001\\u007F\""))
  (should (equal (claude-code-ide-codex--toml-string "é ✓") "\"é ✓\""))
  ;; The escapes of a TOML basic string are those of JSON, so a JSON
  ;; reader gives the text back
  (dolist (text (list "" "line one\nline \"two\" with a backslash \\ here"
                      "literal \\n is not a newline" "$HOME `cmd` 'single' ; | &"
                      (string 0 8 12 27 31 127) "tab\there é ✓"))
    (let ((toml (claude-code-ide-codex--toml-string text)))
      (should-not (string-match-p "[\n\r\t]" toml))
      (should (equal (json-parse-string toml) text)))))

(ert-deftest claude-code-ide-test-codex-developer-instructions ()
  "The instructions are the Emacs prompt of CC, then the user's prompt."
  (let ((claude-code-ide-system-prompt nil))
    (should (equal (claude-code-ide-codex--developer-instructions)
                   claude-code-ide-codex--emacs-prompt)))
  (let ((claude-code-ide-system-prompt "Use \"rg\".\nNever push."))
    (should (equal (claude-code-ide-codex--developer-instructions)
                   (concat claude-code-ide-codex--emacs-prompt "\n\nUse \"rg\".\nNever push."))))
  ;; Claude Code gets the same Emacs prompt
  (let ((claude-code-ide-system-prompt nil)
        (claude-code-ide-cli-extra-flags "")
        (claude-code-ide-cli-debug nil))
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
      (should (string-match-p
               (regexp-quote (shell-quote-argument claude-code-ide-codex--emacs-prompt))
               (claude-code-ide--build-claude-command))))))

;;; Command lines

(ert-deftest claude-code-ide-test-codex-launch-command ()
  "A new conversation: --no-daemon, the instructions, the flags, MCP, the prompt."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let* ((instance (claude-code-ide-codex-tests--instance))
             (result (claude-code-ide-provider-call
                      'codex 'launch instance (claude-code-ide-codex-tests--spec) nil)))
        (should (equal (claude-code-ide-codex-tests--words result)
                       (append (list "codex")
                               (claude-code-ide-codex-tests--common-words)
                               (claude-code-ide-codex-tests--mcp-words))))
        ;; The header value is in the environment, not in the command line
        (should-not (string-match-p claude-code-ide-codex-tests--token
                                    (plist-get result :command)))
        (should (equal (plist-get result :environment)
                       (list "OPENAI_API_KEY" "CODEX_THREAD_ID" "CODEX_SESSION_ID"
                             "CODEX_TOOL_CALL_ID"
                             (concat (claude-code-ide-codex-tests--variable) "="
                                     claude-code-ide-codex-tests--token))))
        (should (eq (claude-code-ide-instance-model instance) 'unknown))
        ;; The first prompt, the Codex flags and ARGS; never Claude flags
        (let* ((claude-code-ide-codex-extra-flags "--model cci-test-model")
               (result (claude-code-ide-codex--launch
                        instance
                        (claude-code-ide-codex-tests--spec :prompt "-cci-test resume now")
                        '("--search"))))
          (should (equal (claude-code-ide-codex-tests--words result)
                         (append (list "codex")
                                 (claude-code-ide-codex-tests--common-words)
                                 (list "--model" "cci-test-model" "--search")
                                 (claude-code-ide-codex-tests--mcp-words)
                                 (list "--" "-cci-test resume now"))))
          (should-not (string-match-p "--cc-only" (plist-get result :command)))
          (should (equal (claude-code-ide-instance-model instance) "cci-test-model")))))))

(ert-deftest claude-code-ide-test-codex-resume-continue-fork-commands ()
  "resume ID, resume --last, the picker and fork have their exact arguments."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let ((instance (claude-code-ide-codex-tests--instance "cci-test-native-1"))
            (base (append (claude-code-ide-codex-tests--common-words)
                          (claude-code-ide-codex-tests--mcp-words))))
        (should (equal (claude-code-ide-codex-tests--words
                        (claude-code-ide-provider-call
                         'codex 'resume instance
                         (claude-code-ide-codex-tests--spec :resume-id "cci-test-native-1") nil))
                       (append '("codex" "resume") base '("--" "cci-test-native-1"))))
        (should (equal (claude-code-ide-codex-tests--words
                        (claude-code-ide-codex--resume
                         instance
                         (claude-code-ide-codex-tests--spec :resume-id "cci-test-native-1"
                                                            :prompt "cci-test go on")
                         nil))
                       (append '("codex" "resume") base
                               '("--" "cci-test-native-1" "cci-test go on"))))
        (should (equal (claude-code-ide-codex-tests--words
                        (claude-code-ide-codex--resume
                         instance (claude-code-ide-codex-tests--spec :continue t) nil))
                       (append '("codex" "resume" "--last") base)))
        (should (equal (claude-code-ide-codex-tests--words
                        (claude-code-ide-codex--resume
                         instance (claude-code-ide-codex-tests--spec :resume t) nil))
                       (append '("codex" "resume") base)))
        ;; Codex would read a prompt after --last or the picker as an ID
        (let ((err (should-error (claude-code-ide-codex--resume
                                  instance (claude-code-ide-codex-tests--spec :continue t :prompt "x")
                                  nil)
                                 :type 'user-error)))
          (should (string-match-p "reads the prompt as a session ID" (cadr err))))
        ;; A fork gets its own native ID later, never the parent's
        (should (equal (claude-code-ide-instance-native-id instance) "cci-test-native-1"))
        (should (equal (claude-code-ide-codex-tests--words
                        (claude-code-ide-provider-call
                         'codex 'fork instance
                         (claude-code-ide-codex-tests--spec :resume-id "cci-test-native-1") nil))
                       (append '("codex" "fork") base '("--" "cci-test-native-1"))))
        (should (eq (claude-code-ide-codex--native-id instance) 'unknown))
        (should-error (claude-code-ide-codex--fork
                       instance (claude-code-ide-codex-tests--spec) nil))))))

(ert-deftest claude-code-ide-test-codex-command-through-shell ()
  "A real shell splits the command into the same words as the eat splitter."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let* ((claude-code-ide-system-prompt "Quote \"this\", 'that', $HOME, `x`.\nLine \\ two.")
             (result (claude-code-ide-codex--launch
                      (claude-code-ide-codex-tests--instance)
                      (claude-code-ide-codex-tests--spec :prompt "cci-test: it's \"done\"?")
                      nil))
             (command (plist-get result :command))
             (words (claude-code-ide-codex-tests--words result)))
        (with-temp-buffer
          ;; The program word becomes printf; the rest are its arguments
          (should (eq 0 (call-process "/bin/sh" nil t nil "-c"
                                      (concat "printf '%s\\0' "
                                              (substring command (length "codex "))))))
          (should (equal (split-string (buffer-string) "\0" t) (cdr words))))
        (let ((instructions (cl-find-if (lambda (word)
                                          (string-prefix-p "developer_instructions=" word))
                                        words)))
          (should (equal (json-parse-string
                          (substring instructions (length "developer_instructions=")))
                         (concat claude-code-ide-codex--emacs-prompt "\n\n"
                                 claude-code-ide-system-prompt))))))))

(ert-deftest claude-code-ide-test-codex-hook-arguments ()
  "The status hooks come through fboundp, and only after the generation."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let ((instance (claude-code-ide-codex-tests--instance))
            (hook-words
             (list "-c" "hooks.SessionStart=[{hooks=[{type=\"command\",command=\"sh /x/h.sh SessionStart\"}]}]"))
            (seen nil))
        ;; Not bound: nothing is added
        (should-not (fboundp 'claude-code-ide-codex-status-hook-args))
        (should-not (cl-some (lambda (word) (string-prefix-p "hooks." word))
                             (claude-code-ide-codex-tests--words
                              (claude-code-ide-codex--launch
                               instance (claude-code-ide-codex-tests--spec) nil))))
        (cl-letf (((symbol-function 'claude-code-ide-codex-status-hook-args)
                   (lambda (inst) (push inst seen) hook-words))
                  ((symbol-function 'claude-code-ide-codex-status-hook-env)
                   (lambda (_inst)
                     (list "CCI_INSTANCE_ID=cci-test-inst" "CCI_GENERATION=1"))))
          (let* ((claude-code-ide-codex-extra-flags "--search")
                 (result (claude-code-ide-codex--launch
                          instance (claude-code-ide-codex-tests--spec) nil)))
            (should (eq (car seen) instance))
            (should (equal (claude-code-ide-codex-tests--words result)
                           (append (list "codex")
                                   (claude-code-ide-codex-tests--common-words)
                                   hook-words
                                   (list "--search")
                                   (claude-code-ide-codex-tests--mcp-words))))
            (should (equal (last (plist-get result :environment) 2)
                           '("CCI_INSTANCE_ID=cci-test-inst" "CCI_GENERATION=1"))))
          ;; A descriptor without its launch generation gets no hooks
          (setf (claude-code-ide-instance-generation instance) 0)
          (setq seen nil)
          (let ((result (claude-code-ide-codex--launch
                         instance (claude-code-ide-codex-tests--spec) nil)))
            (should-not seen)
            (should-not (member "CCI_GENERATION=1" (plist-get result :environment)))))))))

;;; MCP and approvals

(ert-deftest claude-code-ide-test-codex-mcp-setup ()
  "The MCP config keeps the advice's header, through a hidden variable."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let* ((instance (claude-code-ide-codex-tests--instance))
             (setup (claude-code-ide-provider-call 'codex 'mcp-setup instance)))
        (should (equal (plist-get setup :args) (claude-code-ide-codex-tests--mcp-words)))
        (should (equal (plist-get setup :environment)
                       (list (concat (claude-code-ide-codex-tests--variable) "="
                                     claude-code-ide-codex-tests--token)))))
      ;; Without the header advice: no headers, no exclude, no reading
      (advice-remove 'claude-code-ide-mcp-server-get-config
                     #'claude-code-ide-codex-tests--add-header)
      (cl-letf (((symbol-function 'claude-code-ide-codex--read-exclude)
                 (lambda (_) (error "Must not read the config"))))
        (let ((setup (claude-code-ide-codex--mcp-setup (claude-code-ide-codex-tests--instance))))
          (should (equal (plist-get setup :args)
                         '("-c" "mcp_servers.emacs_tools.url=\"http://localhost:40001/mcp/cci-test-sess\""
                           "-c" "mcp_servers.emacs_tools.default_tools_approval_mode=\"prompt\""
                           "-c" "mcp_servers.emacs_tools.tools.claude-code-ide-mcp-project-info.approval_mode=\"approve\"")))
          (should-not (plist-get setup :environment))))
      ;; No MCP server: no config
      (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
        (should-not (claude-code-ide-codex--mcp-setup (claude-code-ide-codex-tests--instance)))
        (should-not (cl-some (lambda (word) (string-prefix-p "mcp_servers." word))
                             (claude-code-ide-codex-tests--words
                              (claude-code-ide-codex--launch
                               (claude-code-ide-codex-tests--instance)
                               (claude-code-ide-codex-tests--spec) nil))))))))

(ert-deftest claude-code-ide-test-codex-user-exclude-list ()
  "The exclude list keeps the user's names; an unreadable list keeps values out of env."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (let ((variable (claude-code-ide-codex-tests--variable))
            (warnings nil))
        ;; The user's list and the new variable
        (let* ((claude-code-ide-codex-tests--exclude '("CCI_USER_SECRET" "AWS_*"))
               (setup (claude-code-ide-codex--mcp-setup (claude-code-ide-codex-tests--instance))))
          (should (member (format "shell_environment_policy.exclude=[\"CCI_USER_SECRET\",\"AWS_*\",\"%s\"]"
                                  variable)
                          (plist-get setup :args))))
        ;; The variable is not listed twice
        (let* ((claude-code-ide-codex-tests--exclude (list variable))
               (setup (claude-code-ide-codex--mcp-setup (claude-code-ide-codex-tests--instance))))
          (should (member (format "shell_environment_policy.exclude=[\"%s\"]" variable)
                          (plist-get setup :args))))
        ;; Not readable: the value goes in http_headers, with one warning
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (let ((claude-code-ide-codex-tests--exclude 'unknown))
            (dotimes (_ 2)
              (let ((setup (claude-code-ide-codex--mcp-setup
                            (claude-code-ide-codex-tests--instance))))
                (should (member (format "mcp_servers.emacs_tools.http_headers={\"X-Emacs-MCP-Token\"=\"%s\"}"
                                        claude-code-ide-codex-tests--token)
                                (plist-get setup :args)))
                (should-not (cl-some (lambda (word)
                                       (or (string-prefix-p "shell_environment_policy" word)
                                           (string-match-p "env_http_headers" word)))
                                     (plist-get setup :args)))
                (should-not (plist-get setup :environment))))))
        (should (= (length warnings) 1))
        (should (string-match-p "argument list" (car warnings)))))))

(ert-deftest claude-code-ide-test-codex-read-exclude ()
  "The exclude list comes from config/read of codex app-server, read only."
  (let* ((codex (claude-code-ide-codex-tests--fake-codex
                 (concat "printf '%s\\0' \"$@\" > \"$D/args\"\n"
                         "while IFS= read -r line; do\n"
                         "  printf '%s\\n' \"$line\" >> \"$D/stdin\"\n"
                         "  case \"$line\" in\n"
                         "    *config/read*) [ -f \"$D/reply\" ] && cat \"$D/reply\" && printf '\\n' ;;\n"
                         "    *'\"id\":1'*) printf '{\"id\":1,\"result\":{}}\\n' ;;\n"
                         "  esac\n"
                         "done\n")))
         (dir (file-name-directory codex))
         (reply (expand-file-name "reply" dir))
         (claude-code-ide-codex-cli-path codex)
         (claude-code-ide-codex-config-read-timeout 5)
         (claude-code-ide-codex-extra-flags "-c 'shell_environment_policy.exclude=[\"CCI_FLAG\"]' --search"))
    (unwind-protect
        (progn
          (with-temp-file reply
            (insert "{\"id\":2,\"result\":{\"config\":{\"shell_environment_policy\":{\"exclude\":[\"CCI_USER_SECRET\"],\"set\":null}},\"origins\":{}}}"))
          (should (equal (claude-code-ide-codex--read-exclude dir) '("CCI_USER_SECRET")))
          ;; The -c of the extra flags count; the app-server reads the project
          (should (equal (claude-code-ide-codex-tests--file-words (expand-file-name "args" dir))
                         '("-c" "shell_environment_policy.exclude=[\"CCI_FLAG\"]" "app-server")))
          (should (string-match-p (regexp-quote (format "\"cwd\":\"%s\"" (expand-file-name dir)))
                                  (with-temp-buffer
                                    (insert-file-contents (expand-file-name "stdin" dir))
                                    (buffer-string))))
          ;; No list of the user
          (with-temp-file reply
            (insert "{\"id\":2,\"result\":{\"config\":{\"shell_environment_policy\":{\"exclude\":null}},\"origins\":{}}}"))
          (should (equal (claude-code-ide-codex--read-exclude dir) nil))
          ;; An error reply
          (with-temp-file reply
            (insert "{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"cci-test\"}}"))
          (should (eq (claude-code-ide-codex--read-exclude dir) 'unknown))
          ;; No reply within the time limit
          (delete-file reply)
          (let ((claude-code-ide-codex-config-read-timeout 0.3)
                (start (float-time)))
            (should (eq (claude-code-ide-codex--read-exclude dir) 'unknown))
            (should (< (- (float-time) start) 3)))
          ;; A profile cannot be read, so nothing runs
          (delete-file (expand-file-name "args" dir))
          (let ((claude-code-ide-codex-extra-flags "-p work"))
            (should (eq (claude-code-ide-codex--read-exclude dir) 'unknown)))
          (should-not (file-exists-p (expand-file-name "args" dir)))
          ;; A missing program
          (let ((claude-code-ide-codex-cli-path (expand-file-name "no-such-codex" dir)))
            (should (eq (claude-code-ide-codex--read-exclude dir) 'unknown))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-test-codex-header-variable-names ()
  "Header names that differ only in punctuation or case get two variables."
  (let ((a (claude-code-ide-codex--header-variable "X-Auth-Token"))
        (b (claude-code-ide-codex--header-variable "X_Auth_Token"))
        (c (claude-code-ide-codex--header-variable "x-auth-token")))
    (should (string-match-p "\\`CCI_MCP_HEADER_X_AUTH_TOKEN_[0-9A-F]\\{8\\}\\'" a))
    (should-not (equal a b))
    (should-not (equal a c))
    (should-not (equal b c))
    (should (equal a (claude-code-ide-codex--header-variable "X-Auth-Token")))))

(ert-deftest claude-code-ide-test-codex-approvals ()
  "Every tool asks by default; only the tools of the allow rule are approved."
  (claude-code-ide-codex-tests--with-mcp
    (let ((server "mcp_servers.emacs_tools")
          (prompt '("-c" "mcp_servers.emacs_tools.default_tools_approval_mode=\"prompt\"")))
      (should (equal (claude-code-ide-codex--approval-args server)
                     (append prompt
                             '("-c" "mcp_servers.emacs_tools.tools.claude-code-ide-mcp-project-info.approval_mode=\"approve\""))))
      ;; The advice removes the name; the full list still has it
      (should-not (member "emacs_eval" (claude-code-ide-mcp-server-get-tool-names)))
      (should (member "emacs_eval" (claude-code-ide-codex--all-tool-names)))
      ;; Without the advice, each registered tool is approved by name
      (advice-remove 'claude-code-ide-mcp-server-get-tool-names
                     #'claude-code-ide-codex-tests--never-auto-allow)
      (should (equal (claude-code-ide-codex--approval-args server)
                     (append prompt
                             '("-c" "mcp_servers.emacs_tools.tools.claude-code-ide-mcp-project-info.approval_mode=\"approve\""
                               "-c" "mcp_servers.emacs_tools.tools.emacs_eval.approval_mode=\"approve\""))))
      ;; A list of allowed tools, with or without the CC prefix; unknown
      ;; names are left out
      (let ((claude-code-ide-mcp-allowed-tools '("mcp__emacs-tools__emacs_eval" "cci-test-absent")))
        (should (equal (claude-code-ide-codex--approval-args server)
                       (append prompt
                               '("-c" "mcp_servers.emacs_tools.tools.emacs_eval.approval_mode=\"approve\"")))))
      (let ((claude-code-ide-mcp-allowed-tools "emacs_eval"))
        (should (equal (claude-code-ide-codex--approval-args server)
                       (append prompt
                               '("-c" "mcp_servers.emacs_tools.tools.emacs_eval.approval_mode=\"approve\"")))))
      ;; No automatic approval
      (let ((claude-code-ide-mcp-allowed-tools nil))
        (should (equal (claude-code-ide-codex--approval-args server) prompt)))
      ;; An approved tool whose name a dotted key cannot hold still asks
      (let ((claude-code-ide-mcp-server-tools
             (append claude-code-ide-mcp-server-tools
                     (list (list :function #'ignore :name "cci.test" :description "x")))))
        (should-not (cl-some (lambda (word) (string-match-p "cci\\.test" word))
                             (claude-code-ide-codex--approval-args server)))))))

;;; Environment

(ert-deftest claude-code-ide-test-codex-environment ()
  "OPENAI_API_KEY is removed by default and kept when the option is off."
  (let ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal)))
    (claude-code-ide-codex-tests--with-mcp
      (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
        (let ((instance (claude-code-ide-codex-tests--instance))
              (spec (claude-code-ide-codex-tests--spec)))
          (should (equal (plist-get (claude-code-ide-codex--launch instance spec nil) :environment)
                         '("OPENAI_API_KEY" "CODEX_THREAD_ID" "CODEX_SESSION_ID"
                           "CODEX_TOOL_CALL_ID")))
          (let ((claude-code-ide-codex-remove-openai-api-key nil))
            (should (equal (plist-get (claude-code-ide-codex--launch instance spec nil)
                                      :environment)
                           '("CODEX_THREAD_ID" "CODEX_SESSION_ID" "CODEX_TOOL_CALL_ID")))
            (should-not (member "OPENAI_API_KEY" (claude-code-ide-codex--process-environment))))
          ;; Codex commands that Emacs runs itself have the same removals
          (should (equal (cl-subseq (claude-code-ide-codex--process-environment) 0 4)
                         '("OPENAI_API_KEY" "CODEX_THREAD_ID" "CODEX_SESSION_ID"
                           "CODEX_TOOL_CALL_ID")))
          ;; No entry sets a credential
          (should-not (cl-some (lambda (entry) (string-match-p "KEY=" entry))
                               (plist-get (claude-code-ide-codex--launch instance spec nil)
                                          :environment))))))))

;;; Both providers in one project

(ert-deftest claude-code-ide-test-codex-and-claude-in-one-project ()
  "CC and Codex in one project: own buffer names, providers and commands."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--clear-processes)
    (let ((state (list :cleanup nil))
          (claude-code-ide-cli-args-functions nil))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-codex--detect)
                     (lambda (&optional _) '(:available t :program "codex" :version unknown))))
            (let* ((cc (claude-code-ide-tests--start-mocked
                        (claude-code-ide-start-spec-create :directory "/tmp/cci-test-both/proj/")
                        state))
                   (cc-buffer (car claude-code-ide-tests--terminal-args))
                   (codex (claude-code-ide-tests--start-mocked
                           (claude-code-ide-start-spec-create
                            :directory "/tmp/cci-test-both/proj/" :provider 'codex
                            :extra-flags "--cc-only")
                           state))
                   (codex-buffer (car claude-code-ide-tests--terminal-args))
                   (cc-instance (claude-code-ide-instance-of-session (car cc)))
                   (codex-instance (claude-code-ide-instance-of-session (car codex))))
              (should (equal cc-buffer "*claude-code[proj]*"))
              (should (string-prefix-p "*codex[proj" codex-buffer))
              (should (eq (claude-code-ide-instance-provider cc-instance) 'claude))
              (should (eq (claude-code-ide-instance-provider codex-instance) 'codex))
              (should-not (equal (claude-code-ide-instance-id cc-instance)
                                 (claude-code-ide-instance-id codex-instance)))
              (should-not (eq (claude-code-ide-instance-session cc-instance)
                              (claude-code-ide-instance-session codex-instance)))
              ;; The start sets the buffer of each descriptor
              (should (eq (claude-code-ide-instance-buffer codex-instance)
                          (claude-code-ide-mcp-session-buffer (car codex))))
              (should (equal (claude-code-ide-instances 'codex) (list codex-instance)))
              (claude-code-ide-codex-tests--with-mcp
                (let ((cc-command (plist-get (funcall (cdr cc)) :command))
                      (codex-words (claude-code-ide-codex-tests--words (funcall (cdr codex)))))
                  (should (string-prefix-p "claude " cc-command))
                  (should (string-match-p "--append-system-prompt" cc-command))
                  (should (equal (cl-subseq codex-words 0 3)
                                 '("codex" "--no-daemon" "--no-alt-screen")))
                  (should-not (member "--cc-only" codex-words))
                  ;; Each command names its own MCP session
                  (should (member (format "mcp_servers.emacs_tools.url=\"http://localhost:40001/mcp/%s\""
                                          (claude-code-ide-mcp-session-session-id (car codex)))
                                  codex-words))
                  (should-not (string-match-p
                               (regexp-quote (claude-code-ide-mcp-session-session-id (car codex)))
                               cc-command))))))
        (claude-code-ide-tests--cleanup-mocked state)))))

;;; Prompts

(ert-deftest claude-code-ide-test-codex-submit-prompt ()
  "submit-prompt runs codex queue in the background with one word per value."
  (let* ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
         (codex (claude-code-ide-codex-tests--fake-codex
                 (concat "printf '%s\\0' \"$@\" > \"$D/args\"\n"
                         "[ -f \"$D/slow\" ] && sleep 5\n"
                         "echo 'Queued message cci-test-msg-1 for thread cci-test-native-1'\n"
                         "exit $(cat \"$D/exit\" 2>/dev/null || echo 0)\n")))
         (dir (file-name-directory codex))
         (claude-code-ide-codex-cli-path codex)
         (claude-code-ide-codex-queue-timeout 5)
         (done nil)
         (claude-code-ide-codex-queue-functions
          (list (lambda (instance result) (push (cons instance result) done)))))
    (cl-letf (((symbol-function 'claude-code-ide--terminal-send-string)
               (lambda (&rest _) (error "Must not type")))
              ((symbol-function 'message) #'ignore))
      (unwind-protect
          (let ((instance (claude-code-ide-codex-tests--instance "cci-test-native-1")))
            (dolist (text '("- fix the test" "--help" "cci-test: say \"hi\"\nline two"))
              (setq done nil)
              (let ((result (claude-code-ide-provider-call 'codex 'submit-prompt instance text)))
                ;; The result comes at once, before the command ends
                (should (equal (cl-subseq result 0 6)
                               '(:status queued :thread "cci-test-native-1" :outcome pending)))
                (should (claude-code-ide-codex-tests--wait
                         (lambda () (not (eq (plist-get result :outcome) 'pending)))))
                (should (eq (plist-get result :outcome) 'queued))
                (should (equal (plist-get result :message-id) "cci-test-msg-1"))
                (should (eq (caar done) instance))
                (should (eq (cdar done) result))
                (should (equal (claude-code-ide-codex-tests--file-words
                                (expand-file-name "args" dir))
                               (list "queue" "--thread=cci-test-native-1"
                                     (concat "--message=" text))))))
            ;; A failed command
            (with-temp-file (expand-file-name "exit" dir) (insert "3"))
            (let ((result (claude-code-ide-codex--submit-prompt instance "cci-test")))
              (should (claude-code-ide-codex-tests--wait
                       (lambda () (not (eq (plist-get result :outcome) 'pending)))))
              (should (eq (plist-get result :outcome) 'failed))
              (should (eq (plist-get result :exit) 3)))
            ;; A command that takes too long is stopped
            (delete-file (expand-file-name "exit" dir))
            (with-temp-file (expand-file-name "slow" dir))
            (let* ((claude-code-ide-codex-queue-timeout 0.3)
                   (result (claude-code-ide-codex--submit-prompt instance "cci-test")))
              (should (claude-code-ide-codex-tests--wait
                       (lambda () (not (eq (plist-get result :outcome) 'pending))) 3))
              (should (eq (plist-get result :outcome) 'timeout)))
            ;; No native ID yet: nothing runs
            (delete-file (expand-file-name "args" dir))
            (should-not (claude-code-ide-codex--submit-prompt
                         (claude-code-ide-codex-tests--instance) "cci-test"))
            (should-not (file-exists-p (expand-file-name "args" dir)))
            ;; A missing program
            (let ((claude-code-ide-codex-cli-path (expand-file-name "no-such-codex" dir)))
              (should-not (claude-code-ide-codex--submit-prompt instance "cci-test"))))
        (delete-directory dir t)))))

;;; Native ID

(ert-deftest claude-code-ide-test-codex-native-id-from-session-start ()
  "Each current SessionStart gives the native ID, also a new one after /new."
  (claude-code-ide-tests--with-instances
    (let* ((claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
           (claude-code-ide-event-functions (list #'claude-code-ide-codex--note-session-start))
           (instance (claude-code-ide-instance-register (claude-code-ide-codex-tests--instance)))
           (start (lambda (generation id)
                    (claude-code-ide-dispatch-event
                     (claude-code-ide-make-event
                      "cci-test-inst" generation 'session-start "SessionStart"
                      `((session_id . ,id) (source . "startup")))))))
      (unwind-protect
          (progn
            (should (eq (claude-code-ide-provider-call 'codex 'native-id instance) 'unknown))
            ;; Other events give no ID
            (claude-code-ide-dispatch-event
             (claude-code-ide-make-event "cci-test-inst" 1 'prompt-submit "UserPromptSubmit"
                                         '((session_id . "cci-test-other"))))
            (should (eq (claude-code-ide-codex--native-id instance) 'unknown))
            (funcall start 1 "cci-test-native-1")
            (should (equal (claude-code-ide-codex--native-id instance) "cci-test-native-1"))
            ;; /new in the same terminal starts a new conversation
            (funcall start 1 "cci-test-native-new")
            (should (equal (claude-code-ide-codex--native-id instance) "cci-test-native-new"))
            ;; A new launch (for example a fork)
            (claude-code-ide-instance-next-generation "cci-test-inst")
            (funcall start 2 "cci-test-native-2")
            (should (equal (claude-code-ide-codex--native-id instance) "cci-test-native-2"))
            (should (equal (claude-code-ide-instance-property
                            instance :codex-native-id-generation)
                           2))
            ;; An event of the old launch is dropped
            (funcall start 1 "cci-test-old")
            (should (equal (claude-code-ide-codex--native-id instance) "cci-test-native-2"))
            ;; An event without an ID changes nothing
            (funcall start 2 nil)
            (should (equal (claude-code-ide-codex--native-id instance) "cci-test-native-2")))
        (claude-code-ide-instance-unregister "cci-test-inst")))))

(ert-deftest claude-code-ide-test-codex-map-event ()
  "Codex hook events map to the common events; the codex-status adapter wins."
  (cl-letf (((symbol-function 'claude-code-ide-codex-events-map-event) nil))
    (should (eq (claude-code-ide-codex--map-event "SessionStart" nil) 'session-start))
    (should (eq (claude-code-ide-codex--map-event "Interrupt" nil) 'interrupt))
    (should (eq (claude-code-ide-codex--map-event "PermissionRequest" nil) 'approval-request))
    (should (eq (claude-code-ide-codex--map-event "PostModelRequest" '((status . "failed")))
                'turn-failed))
    (should (eq (claude-code-ide-codex--map-event "PostModelRequest" '((status . "completed")))
                'other))
    (should (eq (claude-code-ide-codex--map-event "PreCompact" nil) 'other))
    (dolist (pair claude-code-ide-codex--event-map)
      (should (memq (cdr pair) claude-code-ide-event-names))))
  (cl-letf (((symbol-function 'claude-code-ide-codex-events-map-event)
             (lambda (event data) (and (equal event "Stop") (equal data '(x)) 'notification))))
    (should (eq (claude-code-ide-provider-call 'codex 'map-event "Stop" '(x)) 'notification))))

;;; Dialogs

(defconst claude-code-ide-codex-tests--screens
  '((folder-trust . "  You are in /tmp/cci-test-proj\n\n  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.\n  Your trust decision will be saved.\n\n› 1. Trust and continue\n  2. Open restricted\n\n  Press enter to continue\n")
    (update . "  ✨ Update available! 0.164.0 -> 0.169.0\n\n  Release notes: https://github.com/openai/codex/releases/latest\n\n› 1. Update now (runs `brew upgrade --cask codex`)\n  2. Skip\n  3. Skip until next version\n")
    (hooks-review . "  Hooks need review\n  14 hooks are new or changed.\n  Hooks can run outside the sandbox after you trust them.\n\n› 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won't run)\n")
    (approval . "• Calling emacs-tools.emacs_eval\n\n  Allow the emacs-tools MCP server to run tool \"emacs_eval\"?\n\n› 1. Allow\n  2. Cancel\n\n  Press enter to submit\n")
    (approval . "  Would you like to run the following command?\n\n  $ touch ~/cci-test-deny-marker\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for this command in this session (p)\n  3. No, and tell Codex what to do differently (esc)\n")
    ;; Captured in vterm at 38 columns by the live check of this branch
    (folder-trust . " \n  Folder access\n  /Users/rpeck/Source/worktrees/claude\n  -code-ide/feat/codex-launch/tmp/live\n  /proj                               \n \n  Trust this folder? Codex can read,\n  edit, and run files here, subject to\n  your permission settings. Folder\n  settings can run code automatically,\n  even without a model request.\n  Continue only if you trust these\n  files. Your trust decision will be\n  saved.\n\n› 1. Trust and continue                 \n  2. Quit\n\n  enter continue · esc quit\n\n\n\n")
    ;; A narrow terminal wraps the question
    (approval . "  Allow the emacs-tools MCP server\n  to run tool \"emacs_eval\"?\n\n› 1. Allow\n  2. Cancel\n")
    (other . "  Which color do you prefer?\n\n› 1. Red\n  2. Blue\n  3. None of the above\n")
    (nil . "\n  >_ OpenAI Codex (v0.164.0)\n     ~\n\n⚠ Heads up, you have less than 25% of your 5h limit left.\n\n› cci-test-ghostel-ml: reply OK\n  line two\n\n• OK\n\n  Worked for 1s • 2:45 PM\n\n› Ask Codex to do anything\n\n  GPT-5.6-Terra low · ~\n"))
  "Screens of Codex 0.164.0 and the dialog kind of each.
The texts follow the captures and the reports of the T1 and T2 tests.")

(ert-deftest claude-code-ide-test-codex-screen-dialog ()
  "The dialog scan finds each dialog from the screen text and sends no keys."
  (cl-letf (((symbol-function 'claude-code-ide--terminal-send-string)
             (lambda (&rest _) (error "Must not type")))
            ((symbol-function 'process-send-string)
             (lambda (&rest _) (error "Must not send"))))
    (dolist (screen claude-code-ide-codex-tests--screens)
      (let ((buffer (claude-code-ide-codex-tests--screen (cdr screen))))
        (unwind-protect
            (should (eq (claude-code-ide-codex-screen-dialog buffer) (car screen)))
          (kill-buffer buffer))))
    ;; A dialog that scrolled off the screen does not count
    (let ((claude-code-ide-codex--screen-lines 6)
          (buffer (claude-code-ide-codex-tests--screen
                   (concat (alist-get 'hooks-review claude-code-ide-codex-tests--screens)
                           (alist-get nil claude-code-ide-codex-tests--screens)))))
      (unwind-protect
          (progn
            (should-not (claude-code-ide-codex-screen-dialog buffer))
            (let ((claude-code-ide-codex--screen-lines 40))
              (should (eq (claude-code-ide-codex-screen-dialog buffer) 'hooks-review))))
        (kill-buffer buffer)))
    ;; A dead buffer has no dialog
    (let ((buffer (claude-code-ide-codex-tests--screen "› 1. Trust and continue\n")))
      (kill-buffer buffer)
      (should-not (claude-code-ide-codex-screen-dialog buffer)))))

;;; Commands

(ert-deftest claude-code-ide-test-codex-command-starts-codex ()
  "The Codex commands start with the codex provider."
  (let ((claude-code-ide-default-provider 'claude)
        ;; The commands make Codex the current provider; keep that here
        (claude-code-ide--current-provider nil)
        (claude-code-ide--current-provider-read t)
        (claude-code-ide-provider-file (make-temp-name
                                        (expand-file-name "cci-test-provider-" temporary-file-directory)))
        (calls nil))
    (cl-letf (((symbol-function 'claude-code-ide--start-session)
               (lambda (&optional continue resume spec)
                 (push (list claude-code-ide-default-provider continue resume spec) calls))))
      (claude-code-ide-codex)
      (claude-code-ide-codex-continue)
      (claude-code-ide-codex-resume))
    (should (equal (reverse calls)
                   '((codex nil nil nil) (codex t nil nil) (codex nil t nil))))
    (should (eq claude-code-ide-default-provider 'claude))
    (should (eq (claude-code-ide-current-provider) 'codex))
    (ignore-errors (delete-file claude-code-ide-provider-file))))

(provide 'claude-code-ide-codex-tests)

;;; claude-code-ide-codex-tests.el ends here
