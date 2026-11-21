#!/bin/bash

# Combined compile and test check for Claude Code IDE
# This script is used by both GitHub Actions and Claude stop hooks


# Parse command line arguments
HOOK_MODE=false
HOOK_INPUT=""
WITH_NATIVE_COMPILE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --hook)
            HOOK_MODE=true
            # Read JSON input from stdin when in hook mode
            if [ ! -t 0 ]; then
                HOOK_INPUT=$(cat)
            fi
            shift
            ;;
        --with-native-compile)
            WITH_NATIVE_COMPILE=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--hook] [--with-native-compile]" >&2
            exit 1
            ;;
    esac
done

# Get the script's directory and project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT" || exit 1
echo "Running compile and test checks..." >&2

# Find Emacs (EMACS) and the package folders
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
if ! find_emacs; then
    echo "Emacs not found (set EMACS); trying emacs" >&2
    EMACS=emacs
fi

# Mocking primitives with cl-letf makes Emacs 29+ native-compile a
# trampoline, which fails where the C toolchain is broken; mocks work
# without trampolines in batch mode.
NO_TRAMPOLINES="(setq native-comp-enable-subr-trampolines nil)"

# Build load path for dependencies.  LOAD_PATH is an array, so a
# package folder with a space stays one argument.  The optional
# dependencies: websocket, transient (recent releases depend on
# cond-let and llama), vterm, and web-server (the MCP tests that use the
# real web-server package run when it is found, and are skipped
# otherwise)
LOAD_PATH=(-L .)
add_emacs_packages emacs-websocket transient cond-let llama emacs-libvterm web-server

# STEP 1: Compile all elisp files
echo "=== Running byte-compilation check ===" >&2
"$EMACS" -batch "${LOAD_PATH[@]}" \
    --eval "(setq byte-compile-warnings '(not free-vars unresolved))" \
    -f batch-byte-compile *.el
COMPILE_EXIT_CODE=$?

if [ $COMPILE_EXIT_CODE -eq 0 ]; then
    echo "✓ Byte-compilation check passed!" >&2
else
    echo "✗ Byte-compilation failed!" >&2
fi

# STEP 2: Native compile all elisp files (only if byte-compilation succeeded and flag is set)
NATIVE_COMPILE_EXIT_CODE=0
NATIVE_COMPILE_AVAILABLE=false

# Check if native compilation is requested and available
if [ $COMPILE_EXIT_CODE -eq 0 ] && [ "$WITH_NATIVE_COMPILE" = true ]; then
    if "$EMACS" -batch --eval "(if (featurep 'native-compile) (message \"yes\") (message \"no\"))" 2>&1 | grep -q "yes"; then
        NATIVE_COMPILE_AVAILABLE=true
    fi

    if [ "$NATIVE_COMPILE_AVAILABLE" = true ]; then
        echo "" >&2
        echo "=== Running native-compilation check ===" >&2
        "$EMACS" -batch "${LOAD_PATH[@]}" -f batch-native-compile *.el
        NATIVE_COMPILE_EXIT_CODE=$?

        if [ $NATIVE_COMPILE_EXIT_CODE -eq 0 ]; then
            echo "✓ Native-compilation check passed!" >&2
        else
            echo "✗ Native-compilation failed!" >&2
        fi
    else
        echo "" >&2
        echo "=== Native compilation not available in this Emacs version ===" >&2
        echo "✓ Skipping native compilation check" >&2
        # Set exit code to 0 since this is not an error
        NATIVE_COMPILE_EXIT_CODE=0
    fi
elif [ $COMPILE_EXIT_CODE -eq 0 ]; then
    echo "" >&2
    echo "=== Skipping native-compilation (use --with-native-compile to enable) ===" >&2
    # Set exit code to 0 since skipping is intentional
    NATIVE_COMPILE_EXIT_CODE=0
else
    echo "" >&2
    echo "=== Skipping native-compilation due to byte-compilation errors ===" >&2
    NATIVE_COMPILE_EXIT_CODE=1
fi

# STEP 3: Run tests (only if both compilations succeeded)
TEST_FAILED=0
if [ $COMPILE_EXIT_CODE -eq 0 ] && [ $NATIVE_COMPILE_EXIT_CODE -eq 0 ]; then
    echo "" >&2
    echo "=== Running tests ===" >&2
    "$EMACS" -batch "${LOAD_PATH[@]}" --eval "$NO_TRAMPOLINES" -l ert -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit >&2
    TEST_EXIT_CODE=$?

    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo "✓ All tests passed!" >&2
    else
        echo "✗ Tests failed!" >&2
        TEST_FAILED=1
    fi

    # The tests of the scripts: scripts/test-*.sh
    for script_test in "$SCRIPT_DIR"/test-*.sh; do
        echo "" >&2
        echo "=== Running $(basename "$script_test") ===" >&2
        if "$script_test"; then
            echo "✓ $(basename "$script_test") passed!" >&2
        else
            echo "✗ $(basename "$script_test") failed!" >&2
            TEST_FAILED=1
        fi
    done
else
    echo "" >&2
    echo "=== Skipping tests due to compilation errors ===" >&2
    TEST_FAILED=1
fi

# STEP 4: Clean up .elc and .eln files to avoid stale bytecode
echo "" >&2
echo "Cleaning up .elc and .eln files..." >&2
rm -f *.elc
# Native compiled files might be in a subdirectory
find . -name "*.eln" -type f -delete 2>/dev/null || true

# Handle hook mode output
if [ "$HOOK_MODE" = true ]; then
    if [ $COMPILE_EXIT_CODE -ne 0 ]; then
        cat <<EOF
{
  "decision": "block",
  "reason": "✗ Byte-compilation failed! Fix the compilation errors before stopping. Run './scripts/compile-and-test.sh' to see the errors."
}
EOF
        exit 0
    elif [ $NATIVE_COMPILE_EXIT_CODE -ne 0 ]; then
        cat <<EOF
{
  "decision": "block",
  "reason": "✗ Native-compilation failed! Fix the native compilation errors before stopping. Run './scripts/compile-and-test.sh' to see the errors."
}
EOF
        exit 0
    elif [ $TEST_FAILED -eq 1 ]; then
        cat <<EOF
{
  "decision": "block",
  "reason": "✗ Tests failed! Fix the failing tests above before stopping. Run './scripts/compile-and-test.sh' to see the failures again."
}
EOF
        exit 0
    else
        # Success - show summary
        echo "" >&2
        echo "=== Summary ===" >&2
        echo "✓ Byte-compilation: PASSED" >&2
        if [ "$WITH_NATIVE_COMPILE" = true ]; then
            if [ "$NATIVE_COMPILE_AVAILABLE" = true ]; then
                echo "✓ Native-compilation: PASSED" >&2
            else
                echo "✓ Native-compilation: SKIPPED (not available)" >&2
            fi
        else
            echo "✓ Native-compilation: SKIPPED (not requested)" >&2
        fi
        echo "✓ Tests: PASSED" >&2
        echo "✓ All checks passed!" >&2
        exit 0
    fi
fi

# Normal mode: exit with appropriate code
if [ $COMPILE_EXIT_CODE -ne 0 ] || [ $NATIVE_COMPILE_EXIT_CODE -ne 0 ] || [ $TEST_FAILED -eq 1 ]; then
    exit 1
fi

exit 0
