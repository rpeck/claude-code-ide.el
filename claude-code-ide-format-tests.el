;;; claude-code-ide-format-tests.el --- Tests for scripts/format-elisp.el  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the formatter of the format hook, scripts/format-elisp.el.
;; Each test makes a temporary project.  The formatter must format the
;; file, read the indent rules of the macros without running code of
;; the files, ignore rules that are not an integer or `defun', skip
;; Emacs lock files and other files that are not regular readable
;; files, and write no backup file.

;;; Code:

(require 'ert)
(require 'cl-lib)

(declare-function format-elisp-batch "format-elisp" ())

(defconst claude-code-ide-format-tests--script
  (expand-file-name "scripts/format-elisp.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The formatter that the tests load.")

(defvar claude-code-ide-format-tests--ran nil
  "Non-nil when code of a formatted project ran.")

(defun claude-code-ide-format-tests--indent (&rest _)
  "An indent function that the formatter must never call."
  (setq claude-code-ide-format-tests--ran t)
  nil)

(defconst claude-code-ide-format-tests--symbols
  '(cci-test-format-with cci-test-format-lambda cci-test-format-string
                         cci-test-format-fn cci-test-format-sym cci-test-format-def)
  "The symbols whose indent rules the test project declares.")

(defun claude-code-ide-format-tests--write (file text)
  "Write TEXT to FILE."
  (with-temp-file file
    (insert text)))

(ert-deftest claude-code-ide-format-test-rules-locks-and-backups ()
  "The formatter formats the file and uses only the safe indent rules.
It ignores a lambda rule, a string rule and function rules, runs no
code of the project, skips a lock file and a folder named like an
Elisp file, and writes no backup file even where backups are on."
  (load claude-code-ide-format-tests--script nil t)
  (let ((dir (file-name-as-directory (make-temp-file "cci-test-format-" t)))
        (claude-code-ide-format-tests--ran nil))
    (unwind-protect
        (let ((file (expand-file-name "a.el" dir))
              (lock (expand-file-name ".#m.el" dir)))
          (claude-code-ide-format-tests--write
           (expand-file-name "m.el" dir)
           (concat
            "(defmacro cci-test-format-with (x &rest body)\n"
            "  (declare (indent 1))\n  `(progn ,x ,@body))\n"
            "(defmacro cci-test-format-lambda (x)\n"
            "  (declare (indent (lambda (&rest _) (setq claude-code-ide-format-tests--ran t))))\n"
            "  x)\n"
            "(defmacro cci-test-format-string (x)\n  (declare (indent \"two\"))\n  x)\n"
            "(put 'cci-test-format-fn 'lisp-indent-function"
            " #'claude-code-ide-format-tests--indent)\n"
            "(put 'cci-test-format-sym 'lisp-indent-function"
            " 'claude-code-ide-format-tests--indent)\n"
            "(put 'cci-test-format-def 'lisp-indent-function 'defun)\n"
            "(setq claude-code-ide-format-tests--ran t)\n"))
          (claude-code-ide-format-tests--write
           file
           (concat "(cci-test-format-with 1   \n(foo))\n"
                   "(cci-test-format-fn 1\n2)\n"
                   "(cci-test-format-sym 1\n2)\n"
                   "(cci-test-format-lambda 1\n2)\n"))
          ;; An Emacs lock file is a symbolic link to nowhere; this one
          ;; says that another Emacs edits m.el
          (make-symbolic-link "cci-test@host.1234:5678" lock)
          (make-directory (expand-file-name "dir.el" dir))
          (let ((default-directory dir)
                (command-line-args-left (list file lock))
                (make-backup-files t)
                (backup-inhibited nil)
                (backup-enable-predicate #'always))
            (format-elisp-batch))
          (should (equal (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         (concat "(cci-test-format-with 1\n  (foo))\n"
                                 "(cci-test-format-fn 1\n                    2)\n"
                                 "(cci-test-format-sym 1\n                     2)\n"
                                 "(cci-test-format-lambda 1\n                        2)\n")))
          (should-not claude-code-ide-format-tests--ran)
          (should (eql 1 (get 'cci-test-format-with 'lisp-indent-function)))
          (should (eq 'defun (get 'cci-test-format-def 'lisp-indent-function)))
          (dolist (symbol '(cci-test-format-lambda cci-test-format-string
                                                   cci-test-format-fn cci-test-format-sym))
            (should-not (get symbol 'lisp-indent-function)))
          (should-not (file-exists-p (concat file "~")))
          (should (equal (directory-files dir nil "~\\'") nil))
          ;; The lock file is still a link to nowhere
          (should (equal (file-symlink-p lock) "cci-test@host.1234:5678")))
      (dolist (symbol claude-code-ide-format-tests--symbols)
        (put symbol 'lisp-indent-function nil))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-format-test-locked-file-skipped ()
  "A file that another Emacs edits (it has a lock) is not written.
The other files of the run are still formatted."
  (load claude-code-ide-format-tests--script nil t)
  (let ((dir (file-name-as-directory (make-temp-file "cci-test-format-" t))))
    (unwind-protect
        (let ((locked (expand-file-name "a.el" dir))
              (free (expand-file-name "c.el" dir))
              (text "(progn\n1)\n"))
          (claude-code-ide-format-tests--write locked text)
          (claude-code-ide-format-tests--write free text)
          (make-symbolic-link "cci-test@host.1234:5678" (expand-file-name ".#a.el" dir))
          (let ((default-directory dir)
                (command-line-args-left (list locked free)))
            (format-elisp-batch))
          (should (equal text (with-temp-buffer
                                (insert-file-contents locked)
                                (buffer-string))))
          (should (equal "(progn\n  1)\n" (with-temp-buffer
                                            (insert-file-contents free)
                                            (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-format-test-no-backup ()
  "The formatter writes no backup file, also where backups are on."
  (load claude-code-ide-format-tests--script nil t)
  (let ((dir (file-name-as-directory (make-temp-file "cci-test-format-" t))))
    (unwind-protect
        (let ((file (expand-file-name "d.el" dir)))
          (claude-code-ide-format-tests--write file "(progn\n1)\n")
          (let ((default-directory dir)
                (command-line-args-left (list file))
                (make-backup-files t)
                (backup-inhibited nil)
                (backup-enable-predicate #'always))
            (format-elisp-batch))
          (should (equal "(progn\n  1)\n" (with-temp-buffer
                                            (insert-file-contents file)
                                            (buffer-string))))
          (should-not (directory-files dir nil "~\\'")))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-format-test-unchanged-file-not-written ()
  "A file that is already right is not written again."
  (load claude-code-ide-format-tests--script nil t)
  (let ((dir (file-name-as-directory (make-temp-file "cci-test-format-" t))))
    (unwind-protect
        (let ((file (expand-file-name "b.el" dir))
              (text "(defun cci-test-format-b ()\n  1)\n"))
          (claude-code-ide-format-tests--write file text)
          (set-file-times file '(0 0))
          (let ((default-directory dir)
                (command-line-args-left (list file)))
            (format-elisp-batch))
          (should (equal text (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))))
          (should (time-equal-p '(0 0) (file-attribute-modification-time
                                        (file-attributes file)))))
      (delete-directory dir t))))

(provide 'claude-code-ide-format-tests)
;;; claude-code-ide-format-tests.el ends here
