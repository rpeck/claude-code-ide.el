;;; claude-code-ide-reload.el --- Reload the package in a running Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Raymond Peck
;; Keywords: ai, claude, tools

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

;; `claude-code-ide-reload' loads the files of the package again, after
;; an update of the installed files, in a running Emacs.  It loads them
;; in dependency order: each file after the package files that it
;; requires.  A file that fails to load is reported, and the other
;; files still load.
;;
;; The running instances keep running.  A reload evaluates each file
;; again, so functions get their new definitions, but `defvar' and
;; `defcustom' keep their current values: the sessions, the instance
;; descriptors and the registry state stay.  docs/updating.md tells
;; what a reload cannot change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst claude-code-ide-reload--file-regexp
  "\\`claude-code-ide\\(?:-[[:alnum:]-]+\\)?\\.el\\'"
  "Regexp of the names of the package files.")

(defconst claude-code-ide-reload--skip-regexp
  "-\\(?:tests\\|autoloads\\|pkg\\)\\.el\\'"
  "Regexp of the names of the files that a reload never loads.")

(defun claude-code-ide-reload--directory ()
  "Return the directory of the installed package files."
  (if-let* ((library (or (locate-library "claude-code-ide.el" t)
                         (locate-library "claude-code-ide"))))
      (file-name-directory library)
    (user-error "Cannot find the files of claude-code-ide on `load-path'")))

(defun claude-code-ide-reload--package-files (directory)
  "Return the package files in DIRECTORY, without tests and generated files."
  (cl-remove-if (lambda (file)
                  (string-match-p claude-code-ide-reload--skip-regexp file))
                (directory-files directory t claude-code-ide-reload--file-regexp)))

(defun claude-code-ide-reload--feature (file)
  "Return the feature of the package FILE: its name without the extension."
  (intern (file-name-base file)))

(defun claude-code-ide-reload--form-requires (form)
  "Return the features that the top-level FORM requires, in order.
A `require' with a NOERROR argument is optional and does not count.
The forms inside `eval-when-compile', `eval-and-compile' and `progn'
count; the forms inside a function do not."
  (pcase form
    (`(require ',(and feature (pred symbolp)))
     (list feature))
    (`(require ',(and feature (pred symbolp)) ,_)
     (list feature))
    (`(require ',(and feature (pred symbolp)) ,_ nil)
     (list feature))
    (`(,(or 'eval-when-compile 'eval-and-compile 'progn) . ,body)
     (mapcan #'claude-code-ide-reload--form-requires (copy-sequence body)))))

(defun claude-code-ide-reload--requires (file)
  "Return the features that FILE requires at its top level.
A file that cannot be read gives the features of the forms before the
error; its load then reports the error."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((features '())
          (done nil))
      (while (not done)
        (condition-case nil
            (setq features (append features
                                   (claude-code-ide-reload--form-requires
                                    (read (current-buffer)))))
          ((end-of-file invalid-read-syntax error)
           (setq done t))))
      features)))

(defun claude-code-ide-reload--order (files)
  "Return FILES so that each file comes after the files of FILES that it requires.
Files that do not depend on each other keep their order.  A cycle of
requires does not stop the sort: its files come in the order of FILES."
  (let ((by-feature (make-hash-table :test 'eq))
        (state (make-hash-table :test 'eq))
        (result '()))
    (dolist (file files)
      (puthash (claude-code-ide-reload--feature file) file by-feature))
    (cl-labels ((visit (file)
                  (let ((feature (claude-code-ide-reload--feature file)))
                    (unless (gethash feature state)
                      (puthash feature 'visiting state)
                      (dolist (required (claude-code-ide-reload--requires file))
                        (when-let* ((dependency (gethash required by-feature)))
                          (visit dependency)))
                      (puthash feature 'done state)
                      (push file result)))))
      (mapc #'visit files))
    (nreverse result)))

(defun claude-code-ide-reload--report (result)
  "Show the RESULT of a reload: a message, and a warning for each failed file."
  (let ((loaded (plist-get result :loaded))
        (failed (plist-get result :failed)))
    (dolist (failure failed)
      (display-warning 'claude-code-ide
                       (format "Reload: %s failed to load: %s"
                               (file-name-nondirectory (car failure)) (cdr failure))
                       :error))
    (message "Reloaded %d claude-code-ide file%s%s"
             (length loaded) (if (= (length loaded) 1) "" "s")
             (if failed
                 (format "; %d failed: %s" (length failed)
                         (mapconcat (lambda (failure) (file-name-nondirectory (car failure)))
                                    failed ", "))
               ""))))

;;;###autoload
(defun claude-code-ide-reload (&optional directory all)
  "Load the files of claude-code-ide again, in dependency order.
Use it after an update of the installed package, so that a running
Emacs gets the new code without a restart.  DIRECTORY is the folder of
the package files; nil means the folder where `claude-code-ide' is on
`load-path'.  Only the files whose feature is loaded are loaded again,
unless ALL is non-nil; a new file that a loaded file requires loads
with it.  The test files are never loaded.

Each file loads alone: an error in one file is reported, and the other
files still load.  Of each file, the newer of the .el and the .elc
file loads.  The running instances keep running: `defvar' and
`defcustom' keep their values.  This file loads last.

Return a plist: :loaded, the files that loaded, in order, and :failed,
a list of (FILE . ERROR-MESSAGE)."
  (interactive)
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory (claude-code-ide-reload--directory)))))
         (files (claude-code-ide-reload--order
                 (claude-code-ide-reload--package-files directory)))
         (self (cl-find 'claude-code-ide-reload files :key #'claude-code-ide-reload--feature))
         (files (append (remq self files) (and self (list self))))
         (files (if all
                    files
                  (cl-remove-if-not (lambda (file)
                                      (featurep (claude-code-ide-reload--feature file)))
                                    files)))
         (loaded '())
         (failed '()))
    (let ((load-prefer-newer t))
      (dolist (file files)
        (condition-case err
            (progn
              (load (file-name-sans-extension file) nil t)
              (push file loaded))
          (error
           (push (cons file (error-message-string err)) failed)))))
    (let ((result (list :loaded (nreverse loaded) :failed (nreverse failed))))
      (claude-code-ide-reload--report result)
      result)))

(provide 'claude-code-ide-reload)

;;; claude-code-ide-reload.el ends here
