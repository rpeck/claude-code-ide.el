#!/bin/bash

# Tests of format-and-clean.sh in normal mode and of the load path of
# the scripts: files outside the repository stay unchanged, a package
# folder with a space in its path works, and a file that cannot be
# formatted gives a nonzero exit.  The tests use a temporary HOME and a
# temporary project with a copy of the scripts, so they write no file
# of this repository or of the real home folder.  Exit 0 on success.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cci-test-format-clean.XXXXXX") || exit 1
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILED=0
check() {
    if eval "$2"; then
        echo "ok: $1" >&2
    else
        echo "FAIL: $1" >&2
        FAILED=1
    fi
}

# A HOME and a package folder with a space in the path
FAKE_HOME="$WORK/home with space"
PACKAGE="$FAKE_HOME/.emacs.d/elpa/transient-9.9"
MARKER="$WORK/transient-loaded"
mkdir -p "$PACKAGE"
printf '(with-temp-file "%s" (insert "loaded"))\n(provide (quote transient))\n' \
       "$MARKER" > "$PACKAGE/transient.el"

PROJECT="$WORK/project"
OUTSIDE="$WORK/outside"
mkdir -p "$PROJECT/scripts" "$OUTSIDE"
cp "$SCRIPT_DIR/format-and-clean.sh" "$SCRIPT_DIR/common.sh" \
   "$SCRIPT_DIR/format-elisp.el" "$PROJECT/scripts/"

# The checks of paths and failures use a HOME without packages; only
# the check of the load path uses the HOME with a space
PLAIN_HOME="$WORK/plain-home"
mkdir -p "$PLAIN_HOME"
run_format() {
    (cd "$PROJECT" && HOME="$PLAIN_HOME" ./scripts/format-and-clean.sh "$@" 2>&1)
}

# The load path is an array: a folder with a space stays one argument
check "a package folder with a space is one load-path entry" \
      '[ "$(HOME="$FAKE_HOME" bash -c "source \"$SCRIPT_DIR/common.sh\"; LOAD_PATH=(); add_emacs_packages transient; printf \"%s|\" \"\${LOAD_PATH[@]}\"")" = "-L|$PACKAGE|" ]'

# Normal mode: files outside the repository stay unchanged
printf '(progn   \n1)\n' > "$OUTSIDE/init.el"
printf 'cci-test   \n' > "$OUTSIDE/notes.txt"
cp "$OUTSIDE/init.el" "$WORK/init.el.orig"
cp "$OUTSIDE/notes.txt" "$WORK/notes.txt.orig"
ln -s "$OUTSIDE/notes.txt" "$PROJECT/link.txt"
ln -s "$OUTSIDE/init.el" "$PROJECT/link.el"
run_format "$OUTSIDE/init.el" "$OUTSIDE/notes.txt" link.txt link.el >/dev/null
check "normal mode leaves an absolute path outside the repository unchanged" \
      'cmp -s "$OUTSIDE/init.el" "$WORK/init.el.orig"'
check "normal mode leaves the target of a link to outside unchanged" \
      'cmp -s "$OUTSIDE/notes.txt" "$WORK/notes.txt.orig" && [ -L "$PROJECT/link.txt" ] && [ -L "$PROJECT/link.el" ]'

if HOME="$PLAIN_HOME" bash -c "source '$SCRIPT_DIR/common.sh'; find_emacs"; then
    # A project file is formatted
    printf '(progn   \n1)\n' > "$PROJECT/a.el"
    run_format a.el >/dev/null
    check "normal mode formats a file of the repository" \
          '[ "$(cat "$PROJECT/a.el")" = "$(printf "(progn\n  1)")" ]'
    # The formatter gets the package from the folder with a space
    printf '(progn   \n3)\n' > "$PROJECT/c.el"
    (cd "$PROJECT" && HOME="$FAKE_HOME" ./scripts/format-and-clean.sh c.el >/dev/null 2>&1)
    check "the formatter loads a package from a folder with a space" \
          '[ -f "$MARKER" ] && [ "$(cat "$PROJECT/c.el")" = "$(printf "(progn\n  3)")" ]'

    # A file that cannot be written fails the run; the other files are formatted
    printf '(progn\n1)\n' > "$PROJECT/locked.el"
    chmod 444 "$PROJECT/locked.el"
    printf '(progn\n2)\n' > "$PROJECT/b.el"
    OUTPUT=$(run_format locked.el b.el)
    STATUS=$?
    check "a file that cannot be formatted gives a nonzero exit" '[ "$STATUS" != 0 ]'
    check "the run says that it failed" \
          'printf "%s\n" "$OUTPUT" | grep -q "Failed to process: .*/locked.el"'
    check "the other file of the run is still formatted" \
          '[ "$(cat "$PROJECT/b.el")" = "$(printf "(progn\n  2)")" ]'
    OUTPUT=$(cd "$PROJECT" && printf '{"tool_input":{"file_path":"%s"}}' "$PROJECT/locked.el" \
                 | HOME="$PLAIN_HOME" ./scripts/format-and-clean.sh --hook 2>&1)
    STATUS=$?
    check "hook mode gives a nonzero exit for such a file" '[ "$STATUS" != 0 ]'
else
    echo "SKIP: no Emacs; the Elisp formatting checks do not run" >&2
fi

# A text file that cannot be written fails the run
printf 'cci-test   \n' > "$PROJECT/locked.txt"
chmod 444 "$PROJECT/locked.txt"
run_format locked.txt >/dev/null
STATUS=$?
check "a text file that cannot be cleaned gives a nonzero exit" '[ "$STATUS" != 0 ]'

exit $FAILED
