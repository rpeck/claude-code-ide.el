#!/bin/bash

# Test of the --hook mode of format-and-clean.sh: it changes files of
# the repository only.  Files outside it (also through a symbolic link
# inside it), and files under .git/ or tmp/, stay unchanged.
# The test makes a copy of the scripts in a new temporary project, so
# it writes no file of this repository.  Exit 0 on success.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq is not installed (the hook mode needs it)" >&2
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cci-test-format-hook.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/project"
OUTSIDE="$WORK/outside"
mkdir -p "$PROJECT/scripts" "$PROJECT/tmp" "$PROJECT/.git" "$OUTSIDE"
cp "$SCRIPT_DIR/format-and-clean.sh" "$SCRIPT_DIR/common.sh" \
   "$SCRIPT_DIR/format-elisp.el" "$PROJECT/scripts/"

# Every file has trailing whitespace, which the script removes
DIRTY=$(printf 'cci-test line   \n(setq cci-test 1)\t\n')
for file in "$OUTSIDE/init.el" "$OUTSIDE/notes.txt" \
            "$PROJECT/tmp/scratch.txt" "$PROJECT/.git/config.txt" \
            "$PROJECT/inside.txt"; do
    printf '%s\n' "$DIRTY" > "$file"
done
ln -s "$OUTSIDE/notes.txt" "$PROJECT/link.txt"
cp "$OUTSIDE/init.el" "$WORK/init.el.orig"
cp "$OUTSIDE/notes.txt" "$WORK/notes.txt.orig"

run_hook() {
    jq -n --arg path "$1" '{tool_input: {file_path: $path}}' \
        | "$PROJECT/scripts/format-and-clean.sh" --hook 2>/dev/null
}

FAILED=0
check() {
    if eval "$2"; then
        echo "ok: $1" >&2
    else
        echo "FAIL: $1" >&2
        FAILED=1
    fi
}

for path in "$OUTSIDE/init.el" "$OUTSIDE/notes.txt" "$PROJECT/link.txt" \
            "$PROJECT/tmp/scratch.txt" "$PROJECT/.git/config.txt" \
            "$PROJECT/inside.txt"; do
    run_hook "$path"
done

check "a file outside the project is unchanged" \
      'cmp -s "$OUTSIDE/init.el" "$WORK/init.el.orig"'
check "a symbolic link to a file outside the project changes nothing" \
      'cmp -s "$OUTSIDE/notes.txt" "$WORK/notes.txt.orig" && [ -L "$PROJECT/link.txt" ]'
check "a file under tmp/ is unchanged" \
      '[ "$(cat "$PROJECT/tmp/scratch.txt")" = "$DIRTY" ]'
check "a file under .git/ is unchanged" \
      '[ "$(cat "$PROJECT/.git/config.txt")" = "$DIRTY" ]'
check "a file of the project is cleaned" \
      '[ "$(cat "$PROJECT/inside.txt")" = "$(printf "cci-test line\n(setq cci-test 1)")" ]'

exit $FAILED
