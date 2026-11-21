#!/bin/bash

# Combined format and whitespace cleaning for Claude Code IDE
# This avoids file conflicts when both hooks run simultaneously
#
# Usage: format-and-clean.sh FILE...   (normal mode)
#        format-and-clean.sh --hook    (the file path comes as JSON on stdin)
# Only files of this repository are changed, in both modes; see
# project_file_p.  The exit status is nonzero when a file could not be
# formatted or cleaned.

# Get the script's directory and project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"

cd "$PROJECT_ROOT" || exit 1

# Find Emacs (EMACS) the same way as compile-and-test.sh.  Without
# Emacs, Elisp files are not formatted: the script says so once and
# exits with 0
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
HAVE_EMACS=true
if ! find_emacs; then
    HAVE_EMACS=false
fi

# transient gives the indent rules of its own macros; recent releases
# depend on cond-let and llama.  LOAD_PATH is an array, so a folder
# with a space stays one argument
LOAD_PATH=()
add_emacs_packages transient cond-let llama

# Return 0 when FILE (after symbolic links are resolved) is inside
# PROJECT_ROOT, and not under .git/, a tmp/ folder, or a path that Git
# ignores
project_file_p() {
    local file real root relative
    file="$1"
    real=$(resolve_path "$file") || return 1
    root=$(resolve_path "$PROJECT_ROOT") || return 1
    case "$real" in
        "$root"/*) relative="${real#"$root"/}" ;;
        *) return 1 ;;
    esac
    case "/$relative" in
        */.git/*|*/tmp/*) return 1 ;;
    esac
    if command -v git >/dev/null 2>&1 \
            && git -C "$root" check-ignore -q -- "$relative" 2>/dev/null; then
        return 1
    fi
    return 0
}

# Format and clean FILE.  A file that is not a file of this repository
# is skipped: silently in hook mode (a session also edits files outside
# the repository, such as a user's init file), with a message in
# normal mode.  Return 1 when the file could not be processed.
process_file() {
    local file="$1"

    if ! project_file_p "$file"; then
        if [ "$HOOK_MODE" != true ]; then
            echo "Skipping $file: not a file of this repository" >&2
        fi
        return 0
    fi

    # Skip binary files and certain file types
    case "$file" in
        *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.ico|*.svg|*.bin|*.exe|*.dll|*.so|*.dylib|*.elc)
            return 0
            ;;
    esac

    # For Elisp files, format and clean whitespace in one operation
    case "$file" in
        *.el)
            if [ "$HAVE_EMACS" != true ]; then
                if [ -z "$NO_EMACS_REPORTED" ]; then
                    echo "format-and-clean: Emacs not found; Elisp files are not formatted" >&2
                    NO_EMACS_REPORTED=1
                fi
                return 0
            fi
            echo "Formatting and cleaning: $file" >&2

            # The indent rules of the project macros come from the
            # source text; see scripts/format-elisp.el.  It exits with a
            # nonzero status when the file could not be formatted
            if "$EMACS" -batch -L . "${LOAD_PATH[@]}" -l "$SCRIPT_DIR/format-elisp.el" \
                   -f format-elisp-batch "$file" >&2; then
                echo "✓ Formatted and cleaned: $file" >&2
                return 0
            else
                echo "✗ Failed to process: $file" >&2
                return 1
            fi
            ;;
        *)
            # For other text files, just clean whitespace.  Write back
            # through the same file (not sed -i, which differs between
            # GNU and BSD sed and replaces a symbolic link with a copy)
            local cleaned status=0
            cleaned=$(mktemp) || return 1
            if ! sed -e 's/[[:space:]]*$//' "$file" > "$cleaned"; then
                status=1
            elif ! cmp -s "$cleaned" "$file" && ! cat "$cleaned" > "$file"; then
                status=1
            # End the file with a newline
            elif [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ] && ! echo >> "$file"; then
                status=1
            fi
            rm -f "$cleaned"
            if [ "$status" -ne 0 ]; then
                echo "✗ Failed to clean: $file" >&2
                return 1
            fi
            echo "Cleaned whitespace in: $file" >&2
            ;;
    esac

    return 0
}

# Hook mode: read file path from stdin
if [ "$1" = "--hook" ]; then
    HOOK_MODE=true
    # Read input from stdin (Claude passes hook input via stdin)
    HOOK_INPUT=$(cat)

    # Extract the file path from the Write tool input
    FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path')

    # Check if file exists
    if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
        exit 0
    fi

    process_file "$FILE_PATH"
    exit $?
fi

# Normal mode: process files passed as arguments
if [ $# -eq 0 ]; then
    echo "Error: Please specify files to process or use --hook mode" >&2
    exit 1
fi

# Track if any processing failed
FAILED=0

for file in "$@"; do
    # A relative name is relative to the folder of the caller
    case "$file" in
        /*) ;;
        *) file="$CALLER_DIR/$file" ;;
    esac
    if [ -f "$file" ]; then
        if ! process_file "$file"; then
            FAILED=1
        fi
    fi
done

exit $FAILED
