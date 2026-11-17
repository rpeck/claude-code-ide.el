;;; claude-code-ide-provider.el --- Coding-agent provider interface  -*- lexical-binding: t; -*-

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

;; A provider is a coding-agent CLI, such as `claude'.  Each provider is
;; a `claude-code-ide-provider' struct: a name, a display name, a buffer
;; name prefix, and one function for each operation.  The functions keep
;; all that is special to the CLI: its flags, its login, its event
;; formats and its transports.  The rest of the package calls them
;; through `claude-code-ide-provider-call'.
;;
;; `claude-code-ide-register-provider' adds a provider, and
;; `claude-code-ide-get-provider' finds it by its name.  The `claude'
;; provider is defined in claude-code-ide.el.  docs/providers.md
;; describes each operation and its arguments.

;;; Code:

(require 'cl-lib)

(defvar claude-code-ide-default-provider)

(cl-defstruct (claude-code-ide-provider
               (:constructor claude-code-ide-provider-create)
               (:copier nil))
  "A coding-agent CLI and the operations that Emacs uses with it.
Each operation slot holds a function, or nil when the provider does
not support the operation.  docs/providers.md gives the arguments and
the result of each operation."
  (name nil :type symbol :documentation "Symbol that names the provider, such as `claude'.")
  (display-name "" :type string :documentation "Name for people, such as \"Claude Code\".")
  (buffer-name-prefix "" :type string
                      :documentation "Prefix of terminal buffer names, such as \"claude-code\".")
  (detect nil :documentation "(&optional WITH-VERSION) -> (:available :program :version).")
  (launch nil :documentation "(INSTANCE SPEC ARGS) -> (:command :environment).")
  (resume nil :documentation "(INSTANCE SPEC ARGS) -> (:command :environment).")
  (fork nil :documentation "(INSTANCE SPEC ARGS) -> (:command :environment).")
  (submit-prompt nil :documentation "(INSTANCE TEXT) -> non-nil when sent.")
  (stop nil :documentation "(INSTANCE) -> non-nil when stopped.")
  (native-id nil :documentation "(INSTANCE) -> native conversation ID or `unknown'.")
  (status-events nil :documentation "(INSTANCE) -> alist of (EVENT-NAME COMMAND...).")
  (map-event nil :documentation "(PROVIDER-EVENT DATA) -> common event symbol.")
  (mcp-setup nil :documentation "(INSTANCE) -> MCP config in the provider's format.")
  (transcript nil :documentation "(INSTANCE WHAT) -> file, title or model, or `unknown'.")
  (exit-message nil :documentation "(EXIT-CODE SPEC PROGRAM) -> message or nil.")
  (capabilities nil :type list
                :documentation "Symbols of the supported operations.
`claude-code-ide-register-provider' fills it in when it is nil, and
refuses a list that does not name exactly the operations with a
function."))

(defconst claude-code-ide-provider-operations
  '(detect launch resume fork submit-prompt stop native-id status-events
           map-event mcp-setup transcript exit-message)
  "Operation slots of `claude-code-ide-provider'.
The order is that of docs/providers.md.")

(defvar claude-code-ide-provider--registry nil
  "Registered providers, as an alist of (NAME . PROVIDER), oldest first.")

(defun claude-code-ide-provider--operations-of (provider)
  "Return the operations of PROVIDER that have a function, in the standard order."
  (cl-remove-if-not (lambda (operation)
                      (cl-struct-slot-value 'claude-code-ide-provider operation provider))
                    claude-code-ide-provider-operations))

(defun claude-code-ide-register-provider (provider)
  "Register PROVIDER under its name and return it.
A provider of the same name is replaced.  When the capabilities of
PROVIDER are nil, they become its operations that have a function.
Capabilities that name other operations signal an error."
  (unless (claude-code-ide-provider-p provider)
    (signal 'wrong-type-argument (list 'claude-code-ide-provider-p provider)))
  (let ((name (claude-code-ide-provider-name provider))
        (operations (claude-code-ide-provider--operations-of provider)))
    (unless (and name (symbolp name))
      (error "A provider needs a symbol as its name, not %S" name))
    (let ((capabilities (claude-code-ide-provider-capabilities provider)))
      (cond
       ((null capabilities)
        (setf (claude-code-ide-provider-capabilities provider) operations))
       ((cl-set-exclusive-or capabilities operations)
        (error "The capabilities of provider %s are not its operations: %S"
               name (cl-set-exclusive-or capabilities operations)))))
    (if-let* ((cell (assq name claude-code-ide-provider--registry)))
        (setcdr cell provider)
      (setq claude-code-ide-provider--registry
            (append claude-code-ide-provider--registry (list (cons name provider)))))
    provider))

(defun claude-code-ide-get-provider (name)
  "Return the provider registered as NAME, or nil."
  (alist-get name claude-code-ide-provider--registry))

(defun claude-code-ide-provider-names ()
  "Return the names of the registered providers, oldest first."
  (mapcar #'car claude-code-ide-provider--registry))

(defun claude-code-ide-resolve-provider (&optional name)
  "Return the provider NAME, or the default provider when NAME is nil.
NAME can also be a provider struct, which is returned as it is.
Signal a `user-error' when no such provider is registered."
  (cond
   ((claude-code-ide-provider-p name) name)
   ((claude-code-ide-get-provider (or name claude-code-ide-default-provider)))
   (t (user-error "No coding-agent provider named `%s' is registered"
                  (or name claude-code-ide-default-provider)))))

(defun claude-code-ide-provider-supports-p (provider operation)
  "Return non-nil when PROVIDER has a function for OPERATION."
  (unless (memq operation claude-code-ide-provider-operations)
    (error "Unknown provider operation: %S" operation))
  (and (cl-struct-slot-value 'claude-code-ide-provider operation provider) t))

(defun claude-code-ide-provider-unavailable (operation)
  "Return the result of OPERATION that a provider does not support."
  (list :status 'unavailable :capability operation))

(defun claude-code-ide-provider-unavailable-p (result)
  "Return non-nil when RESULT says that an operation is unavailable."
  (and (consp result)
       (keywordp (car result))
       (eq (plist-get result :status) 'unavailable)))

(defun claude-code-ide-provider-call (provider operation &rest args)
  "Call OPERATION of PROVIDER with ARGS and return its result.
PROVIDER is a provider struct or a name.  When PROVIDER has no
function for OPERATION, return (:status unavailable :capability
OPERATION), which `claude-code-ide-provider-unavailable-p' recognizes,
instead of signaling an error."
  (let ((provider (claude-code-ide-resolve-provider provider)))
    (if (claude-code-ide-provider-supports-p provider operation)
        (apply (cl-struct-slot-value 'claude-code-ide-provider operation provider) args)
      (claude-code-ide-provider-unavailable operation))))

(provide 'claude-code-ide-provider)

;;; claude-code-ide-provider.el ends here
