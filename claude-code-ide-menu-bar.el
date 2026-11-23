;;; claude-code-ide-menu-bar.el --- Menu bar entries for claude-code-ide  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two menu bar entries:
;;
;; - Agents: the commands to start, hand over, stop and restore the
;;   coding agents, and to open the status buffer and the registry.
;; - Agent Sessions: one item for each running session, with its state
;;   as the status buffer shows it.  The items are made each time the
;;   menu opens.
;;
;; `claude-code-ide-menu-bar-mode' shows them.  It is on by default.
;; Turn it off with M-x claude-code-ide-menu-bar-mode, or with
;; (setq claude-code-ide-menu-bar-mode nil) before the package loads,
;; or in Customize.

;;; Code:

(require 'easymenu)
(require 'cl-lib)

(declare-function claude-code-ide-mcp--active-sessions "claude-code-ide-mcp" ())
(declare-function claude-code-ide-mcp-session-buffer "claude-code-ide-mcp" (session))
(declare-function claude-code-ide--display-buffer-in-side-window "claude-code-ide" (buffer))
(declare-function claude-code-ide-session-status--rows "claude-code-ide-session-status" (&optional now))
(declare-function claude-code-ide-session-status--item-buffer "claude-code-ide-session-status" (item))
(declare-function claude-code-ide-session-status--visit-session "claude-code-ide-session-status" (item))
(defvar claude-code-ide-session-status--labels)

(defvar claude-code-ide-menu-bar-mode-map (make-sparse-keymap)
  "Keymap of `claude-code-ide-menu-bar-mode'; it holds the two menus.")

;;;###autoload
(define-minor-mode claude-code-ide-menu-bar-mode
  "Show the Agents and the Agent Sessions menus in the menu bar.
Agents has the commands of the package.  Agent Sessions lists the
running sessions with their states, as `claude-code-ide-show-session-status'
does, and an item shows its session.  The mode is on by default."
  :global t
  :init-value t
  :group 'claude-code-ide
  :keymap claude-code-ide-menu-bar-mode-map)

(defconst claude-code-ide-menu-bar--actions-spec
  '("Agents"
    ["Menu..." claude-code-ide-menu]
    "---"
    ["Start (current provider)" claude-code-ide]
    ["Start Codex" claude-code-ide-codex]
    ["Continue last conversation" claude-code-ide-continue]
    ["Resume a conversation..." claude-code-ide-resume]
    ["Toggle current provider" claude-code-ide-toggle-provider]
    ["Switch to agent buffer" claude-code-ide-switch-to-buffer]
    "---"
    ["Hand over..." claude-code-ide-handover]
    ["Answer a waiting handover..." claude-code-ide-handover-resolve]
    "---"
    ["Session status" claude-code-ide-show-session-status]
    ["Session registry" claude-code-ide-list-session-registry]
    ["Reopen a session..." claude-code-ide-reopen-session]
    ["Restore sessions" claude-code-ide-restore-sessions]
    "---"
    ["Stop" claude-code-ide-stop]
    ["Stop all in project" claude-code-ide-stop-all]
    ["Close stopped buffers" claude-code-ide-kill-stopped-buffers]
    "---"
    ["Trust Codex status hooks" claude-code-ide-codex-trust-hooks]
    ["Reload package" claude-code-ide-reload])
  "The easy-menu list of the Agents menu: the commands of the coding agents.")

(easy-menu-define claude-code-ide-menu-bar--actions claude-code-ide-menu-bar-mode-map
  "The Agents menu: the commands of the coding agents."
  claude-code-ide-menu-bar--actions-spec)

(defun claude-code-ide-menu-bar--status-rows-p ()
  "Return non-nil when the status file gives the rows of the sessions.
The file loads on demand, for example with the status mode."
  (fboundp 'claude-code-ide-session-status--rows))

(defun claude-code-ide-menu-bar--show-buffer (buffer)
  "Show BUFFER, a terminal of a session, and select its window."
  (if-let* ((window (get-buffer-window buffer t)))
      (progn
        (select-frame-set-input-focus (window-frame window))
        (select-window window))
    (when-let* ((window (if (fboundp 'claude-code-ide--display-buffer-in-side-window)
                            (claude-code-ide--display-buffer-in-side-window buffer)
                          (display-buffer buffer))))
      (select-window window))))

(defun claude-code-ide-menu-bar--state-label (state)
  "Return the label of the status buffer for STATE, such as \"WAITS FOR YOU\"."
  (or (and (boundp 'claude-code-ide-session-status--labels)
           (car (alist-get state claude-code-ide-session-status--labels)))
      (and state (upcase (symbol-name state)))))

(defun claude-code-ide-menu-bar--row-items ()
  "Return one menu item for each row of the status buffer, in its order."
  (delq nil
        (mapcar (lambda (row)
                  (let* ((item (nth 0 row))
                         (buffer (claude-code-ide-session-status--item-buffer item))
                         (label (claude-code-ide-menu-bar--state-label (nth 1 row))))
                    (when (buffer-live-p buffer)
                      (vector (if label
                                  (format "%s  (%s)" (buffer-name buffer) label)
                                (buffer-name buffer))
                              (lambda ()
                                (interactive)
                                (claude-code-ide-session-status--visit-session item))))))
                (claude-code-ide-session-status--rows))))

(defun claude-code-ide-menu-bar--plain-items ()
  "Return one menu item for each live session, by its buffer name.
The status file is not loaded, so the items have no state."
  (delq nil
        (mapcar (lambda (session)
                  (let ((buffer (claude-code-ide-mcp-session-buffer session)))
                    (when (buffer-live-p buffer)
                      (vector (buffer-name buffer)
                              (lambda ()
                                (interactive)
                                (claude-code-ide-menu-bar--show-buffer buffer))))))
                (claude-code-ide-mcp--active-sessions))))

(defun claude-code-ide-menu-bar--session-items (_items)
  "Return the items of the Agent Sessions menu, made when the menu opens.
Each running session gives one item, then the status buffer and the
registry follow.  Without a session, the first item says so."
  (let ((sessions (ignore-errors
                    (if (claude-code-ide-menu-bar--status-rows-p)
                        (claude-code-ide-menu-bar--row-items)
                      (claude-code-ide-menu-bar--plain-items)))))
    (append (or sessions (list ["No running sessions" ignore :active nil]))
            (list "---"
                  ["Session status buffer" claude-code-ide-show-session-status]
                  ["Session registry" claude-code-ide-list-session-registry]))))

(easy-menu-define claude-code-ide-menu-bar--sessions claude-code-ide-menu-bar-mode-map
  "The Agent Sessions menu: the running sessions and their states."
  '("Agent Sessions"
    :filter claude-code-ide-menu-bar--session-items
    ["No running sessions" ignore :active nil]))

(provide 'claude-code-ide-menu-bar)

;;; claude-code-ide-menu-bar.el ends here
