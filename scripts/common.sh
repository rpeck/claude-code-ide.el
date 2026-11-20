#!/bin/bash

# Shared helpers of compile-and-test.sh and format-and-clean.sh.
# Source this file; it defines functions and sets EMACS.

# Use $EMACS, else emacs on PATH, else a macOS application bundle such
# as "Emacs.app" or "Emacs 30.1.app" (the last one in sort order wins)
find_emacs() {
    if [ -n "$EMACS" ]; then
        return 0
    fi
    EMACS=emacs
    if ! command -v emacs >/dev/null 2>&1; then
        for app in /Applications/Emacs*.app ~/Applications/Emacs*.app; do
            if [ -x "$app/Contents/MacOS/Emacs" ]; then
                EMACS="$app/Contents/MacOS/Emacs"
            fi
        done
    fi
}

# Print the folder of an Emacs package, or return 1 when there is none.
# The first match wins
find_emacs_package() {
    local package="$1"
    # Check common locations
    for dir in \
        ~/.emacs.d/.cache/straight/repos/"$package" \
        ~/.emacs.d/elpa/"$package"* \
        ~/.config/emacs/.cache/straight/repos/"$package" \
        ~/.config/emacs/elpa/"$package"*; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Print the newest ELPA folder PACKAGE-VERSION of PACKAGE (the last one
# in sort order), or return 1 when there is none
find_newest_elpa_package() {
    local package="$1"
    local found=""
    for dir in ~/.emacs.d/elpa/"$package"-[0-9]* ~/.config/emacs/elpa/"$package"-[0-9]*; do
        if [ -d "$dir" ]; then
            found="$dir"
        fi
    done
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
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

find_emacs
