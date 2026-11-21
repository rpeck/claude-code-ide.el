#!/bin/bash

# Shared helpers of compile-and-test.sh and format-and-clean.sh.
# Source this file; it only defines functions.

# Set EMACS to the Emacs to use: $EMACS, else emacs on PATH, else the
# newest macOS application bundle such as "Emacs.app" or "Emacs
# 30.1.app" (the last one in sort order).  Return 1, with EMACS empty,
# when there is none, so that the caller can report it.
find_emacs() {
    if [ -n "$EMACS" ]; then
        if command -v "$EMACS" >/dev/null 2>&1; then
            return 0
        fi
        EMACS=""
        return 1
    fi
    if command -v emacs >/dev/null 2>&1; then
        EMACS=emacs
        return 0
    fi
    for app in /Applications/Emacs*.app ~/Applications/Emacs*.app; do
        if [ -x "$app/Contents/MacOS/Emacs" ]; then
            EMACS="$app/Contents/MacOS/Emacs"
        fi
    done
    [ -n "$EMACS" ]
}

# Print the folder of the Emacs package PACKAGE, or return 1 when there
# is none.  The newest ELPA folder PACKAGE-VERSION wins (by version
# order, in ~/.emacs.d/elpa and ~/.config/emacs/elpa); without one, a
# straight.el repository named PACKAGE.
find_emacs_package() {
    local package="$1"
    local dir newest sort_flags="-k1,1"
    # Version order when sort has it (GNU and recent BSD sort do)
    if sort -V </dev/null >/dev/null 2>&1; then
        sort_flags="-V -k1,1"
    fi
    newest=$(
        for dir in ~/.emacs.d/elpa/"$package"-[0-9]* ~/.config/emacs/elpa/"$package"-[0-9]*; do
            if [ -d "$dir" ]; then
                base="${dir##*/}"
                printf '%s\t%s\n' "${base#"$package"-}" "$dir"
            fi
        done | sort $sort_flags | tail -n 1 | cut -f 2-
    )
    if [ -n "$newest" ]; then
        echo "$newest"
        return 0
    fi
    for dir in ~/.emacs.d/.cache/straight/repos/"$package" \
               ~/.config/emacs/.cache/straight/repos/"$package"; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Add "-L DIR" to the array LOAD_PATH for each PACKAGE that
# find_emacs_package finds.  A folder with a space stays one element.
add_emacs_packages() {
    local package dir
    for package in "$@"; do
        if dir=$(find_emacs_package "$package"); then
            LOAD_PATH+=(-L "$dir")
        fi
    done
}

# Print the absolute path of FILE with all symbolic links resolved
resolve_path() {
    local file="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$file" 2>/dev/null && return 0
    fi
    if readlink -f / >/dev/null 2>&1; then
        readlink -f "$file" 2>/dev/null && return 0
    fi
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$file" 2>/dev/null
}

