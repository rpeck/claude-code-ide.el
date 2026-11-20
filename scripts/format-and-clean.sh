#!/bin/bash

# Combined format and whitespace cleaning for Claude Code IDE
# This avoids file conflicts when both hooks run simultaneously

# Get the script's directory and project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT" || exit 1

# Find Emacs (EMACS) the same way as compile-and-test.sh
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# transient gives the indent rules of its own macros; recent releases
# depend on cond-let and llama
LOAD_PATH=""
for package in transient cond-let llama; do
    if PACKAGE_DIR=$(find_emacs_package "$package"); then
        LOAD_PATH="$LOAD_PATH -L $PACKAGE_DIR"
    fi
done

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

# Function to format and clean a single Elisp file
process_file() {
    local file="$1"

    # Skip binary files and certain file types
    case "$file" in
        *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.ico|*.svg|*.bin|*.exe|*.dll|*.so|*.dylib|*.elc)
            return 0
            ;;
    esac

    # For Elisp files, format and clean whitespace in one operation
    case "$file" in
        *.el)
            echo "Formatting and cleaning: $file" >&2

            # The indent rules of the project macros come from the
            # source text; see scripts/format-elisp.el
            "$EMACS" -batch -L . $LOAD_PATH -l "$SCRIPT_DIR/format-elisp.el" \
                -f format-elisp-batch "$file" >&2

            if [ $? -eq 0 ]; then
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
            local cleaned
            cleaned=$(mktemp) || return 1
            if sed -e 's/[[:space:]]*$//' "$file" > "$cleaned"; then
                if ! cmp -s "$cleaned" "$file"; then
                    cat "$cleaned" > "$file"
                fi
                # End the file with a newline
                if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
                    echo >> "$file"
                fi
            fi
            rm -f "$cleaned"
            echo "Cleaned whitespace in: $file" >&2
            ;;
    esac

    return 0
}

# Hook mode: read file path from stdin
if [ "$1" = "--hook" ]; then
    # Read input from stdin (Claude passes hook input via stdin)
    HOOK_INPUT=$(cat)

    # Extract the file path from the Write tool input
    FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path')

    # Check if file exists
    if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
        exit 0
    fi

    # A session also edits files outside the repository (for example a
    # user's init file).  Process only files of this repository, and
    # skip them silently otherwise
    if ! project_file_p "$FILE_PATH"; then
        exit 0
    fi

    process_file "$FILE_PATH"
    exit $?
fi

# Normal mode: process files passed as arguments
if [ $# -eq 0 ]; then
    echo "Error: Please specify files to process or use --hook mode" >&2
    exit 1
else
    FILES=("$@")
fi

# Track if any processing failed
FAILED=0

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        if ! process_file "$file"; then
            FAILED=1
        fi
    fi
done

exit $FAILED
