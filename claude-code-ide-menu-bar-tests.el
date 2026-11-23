;;; claude-code-ide-menu-bar-tests.el --- Tests for claude-code-ide-menu-bar  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the menu bar entries: the mode and its default, the
;; commands of the Agents menu, and the items of the Agent Sessions
;; menu with and without the status file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide)
(require 'claude-code-ide-menu-bar)

(defun claude-code-ide-menu-bar-tests--commands (menu)
  "Return the commands of the items of the easy-menu MENU, a list."
  (let (commands)
    (dolist (item (cdr menu))
      (cond
       ((vectorp item) (push (aref item 1) commands))
       ((consp item) (setq commands (append (claude-code-ide-menu-bar-tests--commands item)
                                            commands)))))
    commands))

(ert-deftest claude-code-ide-test-menu-bar-mode-default-on ()
  "The menu bar mode is on by default, and its map holds both menus."
  (should (eq (default-value 'claude-code-ide-menu-bar-mode) t))
  (should (eq (eval (car (get 'claude-code-ide-menu-bar-mode 'standard-value)) t) t))
  (let ((menus (mapcar #'car (cdr (lookup-key claude-code-ide-menu-bar-mode-map [menu-bar])))))
    (should (memq 'agents menus))
    (should (memq 'agent\ sessions menus))))

(ert-deftest claude-code-ide-test-menu-bar-mode-off-hides-menus ()
  "With the mode off, the menu bar has neither menu."
  (let ((was claude-code-ide-menu-bar-mode))
    (unwind-protect
        (progn
          (claude-code-ide-menu-bar-mode -1)
          (should-not (key-binding [menu-bar agents]))
          (should-not (key-binding [menu-bar agent\ sessions]))
          (claude-code-ide-menu-bar-mode 1)
          (should (key-binding [menu-bar agents]))
          (should (key-binding [menu-bar agent\ sessions])))
      (claude-code-ide-menu-bar-mode (if was 1 -1)))))

(ert-deftest claude-code-ide-test-menu-bar-actions-are-commands ()
  "Each item of the Agents menu runs a command of the package."
  (require 'claude-code-ide-session-registry)
  (require 'claude-code-ide-session-status)
  (require 'claude-code-ide-reload)
  (let ((commands (claude-code-ide-menu-bar-tests--commands claude-code-ide-menu-bar--actions-spec)))
    (should (> (length commands) 10))
    (dolist (command commands)
      (should (string-prefix-p "claude-code-ide" (symbol-name command)))
      (should (commandp command)))))

(ert-deftest claude-code-ide-test-menu-bar-session-items-from-rows ()
  "With the status file, each row gives one item: its buffer name and its state label.
The items keep the order of the rows, and an item shows its session."
  (require 'claude-code-ide-session-status)
  (let ((one (generate-new-buffer "*cci-test menu one*"))
        (two (generate-new-buffer "*cci-test menu two*"))
        visited)
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide-session-status--rows)
                   (lambda (&optional _now) (list (list 'item-one 'waiting) (list 'item-two 'idle))))
                  ((symbol-function 'claude-code-ide-session-status--item-buffer)
                   (lambda (item) (if (eq item 'item-one) one two)))
                  ((symbol-function 'claude-code-ide-session-status--visit-session)
                   (lambda (item) (push item visited))))
          (let* ((items (claude-code-ide-menu-bar--session-items nil))
                 (sessions (cl-remove-if-not
                            (lambda (item) (and (vectorp item)
                                                (string-match-p "cci-test menu" (aref item 0))))
                            items)))
            (should (equal (mapcar (lambda (item) (aref item 0)) sessions)
                           '("*cci-test menu one*  (NEEDS ANSWER)"
                             "*cci-test menu two*  (WAITS FOR YOU)")))
            (funcall (aref (car sessions) 1))
            (should (equal visited '(item-one)))
            ;; The status buffer and the registry follow the sessions
            (should (memq 'claude-code-ide-show-session-status
                          (claude-code-ide-menu-bar-tests--commands (cons "x" items))))))
      (kill-buffer one)
      (kill-buffer two))))

(ert-deftest claude-code-ide-test-menu-bar-session-items-empty ()
  "Without a running session, the menu says so in one inactive item."
  (cl-letf (((symbol-function 'claude-code-ide-session-status--rows) (lambda (&optional _now) nil)))
    (let ((first (car (claude-code-ide-menu-bar--session-items nil))))
      (should (vectorp first))
      (should (equal (aref first 0) "No running sessions"))
      (should (eq (plist-get (append (substring first 2) nil) :active) nil)))))

(ert-deftest claude-code-ide-test-menu-bar-session-items-without-status-file ()
  "Without the status file, the items are the live sessions, by buffer name."
  (let* ((buffer (generate-new-buffer "*cci-test menu plain*"))
         (session (make-claude-code-ide-mcp-session :buffer buffer))
         shown)
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide-menu-bar--status-rows-p) (lambda () nil))
                  ((symbol-function 'claude-code-ide-mcp--active-sessions) (lambda () (list session)))
                  ((symbol-function 'claude-code-ide-menu-bar--show-buffer)
                   (lambda (b) (push b shown))))
          (let ((item (car (claude-code-ide-menu-bar--session-items nil))))
            (should (equal (aref item 0) "*cci-test menu plain*"))
            (funcall (aref item 1))
            (should (equal shown (list buffer)))))
      (kill-buffer buffer))))

(provide 'claude-code-ide-menu-bar-tests)

;;; claude-code-ide-menu-bar-tests.el ends here
