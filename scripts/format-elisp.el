;;; format-elisp.el --- Indent Elisp files of this project in batch  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Used by format-and-clean.sh:
;;   emacs -batch -L . -l scripts/format-elisp.el -f format-elisp-batch FILE...
;;
;; Each FILE gets `delete-trailing-whitespace' and `indent-region'.
;; Before that, the indent rules of the macros of the project are
;; set.  The indentation of a call to a macro such as
;; `claude-code-ide-mcp-routing-tests--with-state' depends on its
;; (declare (indent N)).  Without that rule, `indent-region' changes
;; every line of a test that uses the macro.  The script reads the
;; rules from the source text and evaluates no code of the files, so it
;; does not load the package or the tests (which change global state).

;;; Code:

(require 'cl-lib)

(defconst format-elisp--macro-definers
  '(defmacro cl-defmacro define-inline)
  "Forms that define a macro and can carry (declare (indent N)).")

(defun format-elisp--valid-rule (rule)
  "Return RULE when it is a rule that the formatter may use, else nil.
Only an integer and the symbol `defun' are valid.  A function as a
rule (a lambda, #\\='FN or another symbol) is never used: indenting
would call it, and the formatter must not run code of the files."
  (and (or (integerp rule) (eq rule 'defun)) rule))

(defun format-elisp--indent-rule (form)
  "Return (NAME . RULE) for a macro FORM with a valid indent declaration.
Return nil for other forms; see `format-elisp--valid-rule'."
  (when (and (consp form)
             (memq (car form) format-elisp--macro-definers)
             (symbolp (nth 1 form)))
    (cl-loop for item in (nthcdr 3 form)
             when (and (consp item) (eq (car item) 'declare))
             do (let ((indent (assq 'indent (cdr-safe item))))
                  (when (and (consp indent) (consp (cdr indent))
                             (format-elisp--valid-rule (cadr indent)))
                    (cl-return (cons (nth 1 form) (cadr indent)))))
             ;; The declaration comes first, after an optional docstring
             unless (or (stringp item)
                        (and (consp item) (memq (car item) '(declare interactive))))
             do (cl-return nil))))

(defun format-elisp--put-rule (form)
  "Return (NAME . RULE) for FORM `(put \\='NAME \\='lisp-indent-function RULE)'.
Return nil when RULE is not valid; see `format-elisp--valid-rule'."
  (when (and (consp form)
             (memq (car form) '(put function-put))
             (eq (car-safe (nth 1 form)) 'quote)
             (symbolp (car-safe (cdr-safe (nth 1 form))))
             (equal (nth 2 form) ''lisp-indent-function))
    (let* ((rule (nth 3 form))
           (value (if (eq (car-safe rule) 'quote) (car-safe (cdr-safe rule)) rule)))
      (when (format-elisp--valid-rule value)
        (cons (cadr (nth 1 form)) value)))))

(defun format-elisp--file-p (file)
  "Return non-nil when FILE is a regular readable file, and no lock file.
Emacs lock files (.#NAME) are symbolic links to nowhere."
  (and (not (string-prefix-p ".#" (file-name-nondirectory file)))
       (file-regular-p file)
       (file-readable-p file)))

(defun format-elisp--file-rules (file)
  "Return the indent rules of the top-level forms of FILE.
The forms are read, not evaluated.  A file that cannot be read gives
the rules up to the error, and a file that is not a regular readable
file gives none."
  (let ((rules nil))
    (when (format-elisp--file-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (condition-case nil
                (while t
                  (let* ((form (read (current-buffer)))
                         (rule (or (format-elisp--indent-rule form)
                                   (format-elisp--put-rule form))))
                    (when rule
                      (push rule rules))))
              (error nil)))
        (error (message "format-elisp: cannot read %s: %s"
                        file (error-message-string err)))))
    rules))

(defun format-elisp-set-rules (files)
  "Set the indent rules of the macros in FILES.
Return the number of rules."
  (let ((count 0))
    (dolist (file files count)
      (dolist (rule (format-elisp--file-rules file))
        (put (car rule) 'lisp-indent-function (cdr rule))
        (setq count (1+ count))))))

(defun format-elisp-file (file)
  "Delete trailing whitespace in FILE and indent it; write it when it changed.
The file is read into a temporary buffer, not visited, so no file
local variable, mode hook of the file or backup takes part.  Return
non-nil when FILE changed."
  (let ((make-backup-files nil))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((coding last-coding-system-used)
            (before (buffer-string)))
        (delay-mode-hooks (emacs-lisp-mode))
        (setq-local indent-tabs-mode nil)
        (delete-trailing-whitespace)
        (indent-region (point-min) (point-max))
        (unless (string= before (buffer-string))
          (let ((coding-system-for-write coding))
            (write-region nil nil file nil 'silent))
          t)))))

(defun format-elisp-run (files)
  "Format FILES, and return the files that could not be formatted.
The indent rules come from the Elisp files in `default-directory' (the
project root) and from FILES.  A file that cannot be read or formatted
gets a message, and the other files are still formatted.  A file that
is not a regular readable file (such as a lock file) is skipped, and
is no failure."
  ;; A transient whose dependencies are missing signals an error
  (ignore-errors (require 'transient nil t))
  (format-elisp-set-rules
   (delete-dups (append (directory-files default-directory t "\\.el\\'")
                        (mapcar #'expand-file-name files))))
  (let ((failed nil))
    (dolist (file files)
      (if (not (format-elisp--file-p file))
          (message "format-elisp: skipping %s: not a regular readable file" file)
        (condition-case err
            (format-elisp-file file)
          (error (message "format-elisp: cannot format %s: %s"
                          file (error-message-string err))
                 (push file failed)))))
    (nreverse failed)))

(defun format-elisp-batch ()
  "Format the files of `command-line-args-left', for a batch Emacs.
See `format-elisp-run'.  Emacs exits with status 1 when a file could
not be formatted, after all the files are done."
  (let ((files command-line-args-left))
    (setq command-line-args-left nil)
    (when (format-elisp-run files)
      (kill-emacs 1))))

(provide 'format-elisp)
;;; format-elisp.el ends here
