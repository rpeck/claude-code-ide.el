# Updating the package in a running Emacs

This document tells how to update claude-code-ide and load the new code into an Emacs that runs sessions, without a restart.

Code: `claude-code-ide-reload.el`.

## Summary

1. Update the installed files.
2. Run `M-x load-library RET claude-code-ide-reload RET`.
3. Run `M-x claude-code-ide-reload`.
4. Read the message. Fix each file that it names, and run the command again.

The running Claude Code and Codex instances keep running.

## Step 1: update the installed files

The command depends on how you installed the package.

| Install | Update command |
|---|---|
| `use-package` with `:vc` (Emacs 30) | `M-x package-vc-upgrade RET claude-code-ide RET` |
| `package.el` from an archive | `M-x package-upgrade RET claude-code-ide RET` |
| `straight.el` | `M-x straight-pull-package RET claude-code-ide RET`, then `M-x straight-rebuild-package RET claude-code-ide RET` |
| Doom Emacs | `doom upgrade` or `doom sync -u` in a terminal |
| A local checkout on `load-path` | `git pull` (or `git checkout <branch>`) in the checkout |

Notes:

- **`package.el` and `:vc` installs** compile the new files. `package.el` can also load the new files of a loaded package itself (`package--reload-previously-loaded`). The reload is still safe to run: it keeps the dependency order and reports each failure.
- **A local checkout** is not compiled by the update. If an old `.elc` file is next to an `.el` file, the reload loads the newer of the two, so the old `.elc` file does not hide the new code.
- **Check the folder.** `(locate-library "claude-code-ide")` must name the folder that you updated. Another copy earlier in `load-path` hides it (see "From a local checkout" in `README.org`).

## Step 2: load the reload command

`claude-code-ide-reload` is in its own file. A new file of an update is not loaded yet, so load it one time:

```
M-x load-library RET claude-code-ide-reload RET
```

With a `package.el` or `:vc` install, the command is autoloaded, and this step is not necessary.

## Step 3: reload

```
M-x claude-code-ide-reload
```

The command does these things:

1. It finds the package folder: the folder of `claude-code-ide` on `load-path`.
2. It sorts the package files so that each file comes after the package files that it requires at its top level. Optional requires (`(require 'x nil t)`) do not count, because the main file loads its optional files after its own `provide`.
3. It loads each file whose feature is loaded now, in that order. It loads `claude-code-ide-reload.el` last.
4. It reports the result: "Reloaded N claude-code-ide files", and the names of the files that failed.

Details:

- **Test files** (`*-tests.el`) and generated files (`*-autoloads.el`, `*-pkg.el`) never load.
- **A file that is not loaded** stays unloaded, for example `claude-code-ide-transient.el` when you never opened the menu. From Lisp, `(claude-code-ide-reload nil t)` loads all files.
- **A new file** of the update loads when a reloaded file requires it. The main file loads its optional files (`claude-code-ide-codex`, `-control`, `-transcript`, `-handover`, `-review`) this way.
- **From Lisp:** `(claude-code-ide-reload DIRECTORY ALL)` returns a plist with `:loaded` (the files, in order) and `:failed` (a list of `(FILE . ERROR-MESSAGE)`).

## Step 4: failures

- Each file loads alone. An error in one file does not stop the other files.
- The command shows a warning for each failed file, with the error. The message names the failed files.
- A file that failed can be half loaded: the forms before the error have their new definitions, and the forms after it keep the old ones.
- Fix the cause (for example, finish a `git pull` with a conflict), and run `M-x claude-code-ide-reload` again.

## What stays, and what a reload cannot change

The reload evaluates each file again. These values stay:

- **Running instances.** The terminal buffers, the CLI processes, the MCP sessions, and the instance descriptors stay. Their CLIs do not restart.
- **Variables.** `defvar` and `defcustom` do not change a variable that has a value. Your settings and the state of the package (the session registry queue, the status of each instance, the inboxes) stay.
- **Modes.** `claude-code-ide-session-registry-mode` and `claude-code-ide-session-status-mode` stay on. Their hooks point to function names, so they run the new code.
- **Constants change.** `defconst` takes its new value. A provider registers itself again with its new operations. That is the wanted result.

These things do not change until a restart, or until you do them by hand:

- **Closures that already exist.** A timer or a hook that holds a `lambda` keeps the old code until it is made again. For example, the process sentinel of a running instance keeps the old code. A new instance gets the new code.
- **Struct changes.** When an update adds a slot to a `cl-defstruct` whose objects live in memory (for example `claude-code-ide-mcp-session` or `claude-code-ide-instance`), the objects of the running instances have the old layout. Restart Emacs after such an update. The registry entries are read from the file each time, so their struct can change without a restart.
- **A changed hook or advice name.** When an update removes or renames a function that is in a hook, the hook keeps the old name. Turn the mode off and on again.
- **Running CLIs.** A change of the CLI command line, the MCP config, or the status hooks reaches only new launches. To give a running instance the new command line, end it and resume it (`M-x claude-code-ide-reopen-session`).
- **Byte-compiled callers.** A macro change reaches only the files that load after the macro's file. The dependency order makes sure of this for package files.

When you are not sure, restart Emacs. After a restart, `M-x claude-code-ide-restore-sessions` starts the sessions that ran again (see `docs/session-schema.md`, "Restore").
