#!/bin/bash

# Tests of scripts/common.sh and of format-and-clean.sh without Emacs.
# They use a temporary HOME and a temporary project, so they read and
# write no file of this repository or of the real home folder.  Exit 0
# on success.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cci-test-common.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
check() {
    if eval "$2"; then
        echo "ok: $1" >&2
    else
        echo "FAIL: $1" >&2
        FAILED=1
    fi
}

# The newest ELPA folder wins, in version order
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.emacs.d/elpa/cci-pkg-0.9.4" \
         "$FAKE_HOME/.emacs.d/elpa/cci-pkg-0.11.0" \
         "$FAKE_HOME/.emacs.d/elpa/cci-pkg-0.10.0" \
         "$FAKE_HOME/.emacs.d/elpa/cci-pkgextra-9.0" \
         "$FAKE_HOME/.emacs.d/elpa/cci-other-1.0" \
         "$FAKE_HOME/.emacs.d/.cache/straight/repos/cci-straight"
touch "$FAKE_HOME/.emacs.d/elpa/cci-pkg-9.9.signed"
run_common() {
    HOME="$FAKE_HOME" bash -c "source '$SCRIPT_DIR/common.sh'; $1"
}
check "the newest ELPA folder in version order" \
      '[ "$(run_common "find_emacs_package cci-pkg")" = "$FAKE_HOME/.emacs.d/elpa/cci-pkg-0.11.0" ]'
check "another package with the same prefix does not match" \
      '! run_common "find_emacs_package cci-pkgext" >/dev/null'
check "a straight.el repository when there is no ELPA folder" \
      '[ "$(run_common "find_emacs_package cci-straight")" = "$FAKE_HOME/.emacs.d/.cache/straight/repos/cci-straight" ]'
check "no folder gives status 1 and no output" \
      '[ -z "$(run_common "find_emacs_package cci-missing")" ] && ! run_common "find_emacs_package cci-missing"'

# find_emacs reports an Emacs that is not there
check "find_emacs fails for an EMACS that does not exist" \
      '! EMACS="$WORK/no-such-emacs" run_common "find_emacs"'

# Without Emacs, format-and-clean.sh skips Elisp files with one message
PROJECT="$WORK/project"
mkdir -p "$PROJECT/scripts"
cp "$SCRIPT_DIR/format-and-clean.sh" "$SCRIPT_DIR/common.sh" \
   "$SCRIPT_DIR/format-elisp.el" "$PROJECT/scripts/"
printf '(progn   \n1)\n' > "$PROJECT/a.el"
printf '(progn   \n2)\n' > "$PROJECT/b.el"
cp "$PROJECT/a.el" "$WORK/a.el.orig"
cp "$PROJECT/b.el" "$WORK/b.el.orig"
OUTPUT=$(cd "$PROJECT" && HOME="$FAKE_HOME" EMACS="$WORK/no-such-emacs" \
             ./scripts/format-and-clean.sh a.el b.el 2>&1)
STATUS=$?
check "without Emacs the script exits with 0" '[ "$STATUS" = 0 ]'
check "without Emacs the script says so once" \
      '[ "$(printf "%s\n" "$OUTPUT" | grep -c "Emacs not found")" = 1 ]'
check "without Emacs the Elisp files are unchanged" \
      'cmp -s "$PROJECT/a.el" "$WORK/a.el.orig" && cmp -s "$PROJECT/b.el" "$WORK/b.el.orig"'

exit $FAILED
