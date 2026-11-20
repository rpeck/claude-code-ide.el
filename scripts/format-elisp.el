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

(defun format-elisp--indent-rule (form)
  "Return (NAME . RULE) for a macro FORM with an indent declaration, or nil."
  (when (and (consp form)
             (memq (car form) format-elisp--macro-definers)
             (symbolp (nth 1 form)))
    (cl-loop for item in (nthcdr 3 form)
             when (and (consp item) (eq (car item) 'declare))
             do (let ((indent (assq 'indent (cdr item))))
                  (when indent
                    (cl-return (cons (nth 1 form) (cadr indent)))))
             ;; The declaration comes first, after an optional docstring
             unless (or (stringp item)
                        (and (consp item) (memq (car item) '(declare interactive))))
             do (cl-return nil))))

(defun format-elisp--put-rule (form)
  "Return (NAME . RULE) for FORM `(put \\='NAME \\='lisp-indent-function RULE)'."
  (when (and (consp form)
             (memq (car form) '(put function-put))
             (eq (car-safe (nth 1 form)) 'quote)
             (equal (nth 2 form) ''lisp-indent-function))
    (let ((rule (nth 3 form)))
      (cons (cadr (nth 1 form))
            (if (eq (car-safe rule) 'quote) (cadr rule) rule)))))

(defun format-elisp--file-rules (file)
  "Return the indent rules of the top-level forms of FILE.
The forms are read, not evaluated.  A file that cannot be read gives
the rules up to the error."
  (let ((rules nil))
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
  "Delete trailing whitespace in FILE and indent it; save it when it changed."
  (with-current-buffer (find-file-noselect file)
    (emacs-lisp-mode)
    (setq-local indent-tabs-mode nil)
    (delete-trailing-whitespace)
    (indent-region (point-min) (point-max))
    (when (buffer-modified-p)
      (save-buffer))
    (kill-buffer)))

(defun format-elisp-batch ()
  "Format the files of `command-line-args-left'.
The indent rules come from the Elisp files in `default-directory' (the
project root) and from the files to format."
  (let ((files command-line-args-left))
    (setq command-line-args-left nil)
    ;; A transient whose dependencies are missing signals an error
    (ignore-errors (require 'transient nil t))
    (format-elisp-set-rules
     (delete-dups (append (directory-files default-directory t "\\.el\\'")
                          (mapcar #'expand-file-name files))))
    (dolist (file files)
      (format-elisp-file file))))

(provide 'format-elisp)
;;; format-elisp.el ends here
