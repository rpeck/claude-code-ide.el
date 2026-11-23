;;; claude-code-ide-reload-tests.el --- Tests for claude-code-ide-reload  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for `claude-code-ide-reload': the dependency order, the files
;; that it loads, and a reload in a new batch Emacs with a broken file
;; while an instance runs.  The test Emacs itself is never reloaded.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide-reload)

(defun claude-code-ide-reload-tests--write (dir name &rest forms)
  "Write the file NAME in DIR with FORMS, each printed on its own line."
  (with-temp-file (expand-file-name name dir)
    (dolist (form forms)
      (prin1 form (current-buffer))
      (insert "\n"))))

(ert-deftest claude-code-ide-test-reload-order ()
  "Each file loads after the package files that it requires.
Optional requires, requires inside functions, other packages, tests
and cycles do not change the order."
  (let ((dir (make-temp-file "cci-test-reload-order-" t)))
    (unwind-protect
        (progn
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-a.el"
           '(require 'claude-code-ide) '(provide 'claude-code-ide-a))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-b.el"
           '(require 'cl-lib)
           '(eval-when-compile (require 'claude-code-ide-c))
           '(require 'claude-code-ide-a nil t)
           '(defun claude-code-ide-b-f () (require 'claude-code-ide-a))
           '(provide 'claude-code-ide-b))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-c.el" '(provide 'claude-code-ide-c))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide.el"
           '(require 'claude-code-ide-b) '(provide 'claude-code-ide)
           '(require 'claude-code-ide-a nil t))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-x.el" '(require 'claude-code-ide-y) '(provide 'claude-code-ide-x))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-y.el" '(require 'claude-code-ide-x) '(provide 'claude-code-ide-y))
          (claude-code-ide-reload-tests--write
           dir "claude-code-ide-a-tests.el" '(require 'claude-code-ide-a))
          (with-temp-file (expand-file-name "claude-code-ide-broken.el" dir)
            (insert "(require 'claude-code-ide-c)\n(defun broken (\n"))
          (let ((names (mapcar #'file-name-nondirectory
                               (claude-code-ide-reload--order
                                (claude-code-ide-reload--package-files dir)))))
            (should-not (member "claude-code-ide-a-tests.el" names))
            (should (= (length names) 7))
            (cl-flet ((before (a b) (< (cl-position a names :test #'equal)
                                       (cl-position b names :test #'equal))))
              (should (before "claude-code-ide-c.el" "claude-code-ide-b.el"))
              (should (before "claude-code-ide-b.el" "claude-code-ide.el"))
              (should (before "claude-code-ide.el" "claude-code-ide-a.el"))
              (should (before "claude-code-ide-c.el" "claude-code-ide-broken.el")))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-test-reload-order-of-the-package ()
  "The files of the package itself load after their dependencies."
  (let* ((dir (file-name-directory (locate-library "claude-code-ide-reload.el" t)))
         (names (mapcar #'file-name-nondirectory
                        (claude-code-ide-reload--order
                         (claude-code-ide-reload--package-files dir)))))
    (cl-flet ((before (a b) (< (cl-position a names :test #'equal)
                               (cl-position b names :test #'equal))))
      (should (before "claude-code-ide-provider.el" "claude-code-ide.el"))
      (should (before "claude-code-ide-mcp.el" "claude-code-ide.el"))
      (should (before "claude-code-ide.el" "claude-code-ide-session-registry.el"))
      (should (before "claude-code-ide-session-registry.el" "claude-code-ide-session-status.el"))
      (should (before "claude-code-ide-session-status.el" "claude-code-ide-codex-events.el"))
      (should (before "claude-code-ide.el" "claude-code-ide-codex.el")))
    (should-not (cl-some (lambda (name) (string-match-p "-tests\\.el\\'" name)) names))))

(ert-deftest claude-code-ide-test-reload-in-batch-emacs ()
  "A reload in a new Emacs loads each loaded file, reports a broken one,
and keeps a running instance and the state of the package.  A package
mode that is on is turned off and on again, so that it installs the
hooks of the new version."
  (let* ((dir (make-temp-file "cci-test-reload-" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (package-dir (file-name-directory (locate-library "claude-code-ide-reload.el" t)))
         (script (expand-file-name "cci-test-reload.el" dir)))
    (unwind-protect
        (progn
          ;; A copy of the installed package
          (dolist (file (claude-code-ide-reload--package-files package-dir))
            (copy-file file (expand-file-name (file-name-nondirectory file) dir)))
          (with-temp-file script
            (insert
             (prin1-to-string
              `(progn
                 (setq native-comp-enable-subr-trampolines nil)
                 (require 'claude-code-ide)
                 (require 'claude-code-ide-session-registry)
                 (require 'claude-code-ide-reload)
                 (let* ((process (start-process "cci-test-live" nil "sleep" "30"))
                        (instance (claude-code-ide-instance-register
                                   (claude-code-ide-instance-create
                                    :id "cci-test-reload-live" :provider 'claude))))
                   (setq claude-code-ide-cli-extra-flags "--cci-test-kept")
                   ;; The registry mode is on, in a temporary folder.  The
                   ;; old version had no event hook: the reload must add it.
                   (setq claude-code-ide-state-file ,(expand-file-name "state.json" dir))
                   (claude-code-ide-session-registry-mode 1)
                   (remove-hook 'claude-code-ide-event-functions
                                #'claude-code-ide-session-registry--on-event)
                   ;; The update: a new function, and a broken file
                   (with-temp-buffer
                     (insert "\n(defun claude-code-ide-cci-test-new () 'cci-test-new)\n")
                     (append-to-file (point-min) (point-max)
                                     ,(expand-file-name "claude-code-ide-provider.el" dir)))
                   (with-temp-buffer
                     (insert "\n(defun cci-test-broken (\n")
                     (append-to-file (point-min) (point-max)
                                     ,(expand-file-name "claude-code-ide-transcript.el" dir)))
                   (let* ((result (claude-code-ide-reload ,dir))
                          (loaded (mapcar #'file-name-nondirectory (plist-get result :loaded))))
                     (princ (format "failed=%S\n"
                                    (mapcar (lambda (failure) (file-name-nondirectory (car failure)))
                                            (plist-get result :failed))))
                     (princ (format "new=%S\n" (and (fboundp 'claude-code-ide-cci-test-new)
                                                    (funcall 'claude-code-ide-cci-test-new))))
                     (princ (format "kept=%S\n" claude-code-ide-cli-extra-flags))
                     (princ (format "hooked=%S\n"
                                    (and (memq #'claude-code-ide-session-registry--on-event
                                               claude-code-ide-event-functions)
                                         claude-code-ide-session-registry-mode
                                         t)))
                     (princ (format "modes=%S\n" (plist-get result :modes)))
                     (princ (format "instance=%S\n" (eq (claude-code-ide-instance-by-id
                                                         "cci-test-reload-live")
                                                        instance)))
                     (princ (format "process=%S\n" (and (process-live-p process) t)))
                     (princ (format "order=%S\n"
                                    (< (cl-position "claude-code-ide-provider.el" loaded :test #'equal)
                                       (cl-position "claude-code-ide.el" loaded :test #'equal)
                                       (cl-position "claude-code-ide-session-registry.el" loaded
                                                    :test #'equal))))
                     (princ (format "last=%S\n" (car (last loaded))))
                     (princ (format "tests=%S\n" (cl-some (lambda (name)
                                                            (string-match-p "-tests" name))
                                                          loaded)))
                     (delete-process process)))))))
          (with-temp-buffer
            (let ((status (apply #'call-process emacs nil t nil "-Q" "-batch" "-L" dir
                                 (append (mapcan (lambda (path) (list "-L" path))
                                                 (cl-remove-if (lambda (path)
                                                                 (or (not (stringp path))
                                                                     (file-equal-p path package-dir)))
                                                               load-path))
                                         (list "-l" script)))))
              (should (eq status 0))
              (let ((output (buffer-string)))
                (should (string-match-p "failed=(\"claude-code-ide-transcript.el\")" output))
                (should (string-match-p "new=cci-test-new" output))
                (should (string-match-p "kept=\"--cci-test-kept\"" output))
                (should (string-match-p "hooked=t" output))
                (should (string-match-p "modes=(claude-code-ide-session-registry-mode claude-code-ide-menu-bar-mode)" output))
                (should (string-match-p "instance=t" output))
                (should (string-match-p "process=t" output))
                (should (string-match-p "order=t" output))
                (should (string-match-p "last=\"claude-code-ide-reload.el\"" output))
                (should (string-match-p "tests=nil" output))
                (should (string-match-p "Reloaded [0-9]+ claude-code-ide files; 1 failed: claude-code-ide-transcript.el; restarted claude-code-ide-session-registry-mode"
                                        output))))))
      (delete-directory dir t))))

(provide 'claude-code-ide-reload-tests)

;;; claude-code-ide-reload-tests.el ends here
