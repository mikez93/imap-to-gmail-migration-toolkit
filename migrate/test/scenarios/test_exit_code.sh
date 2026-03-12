#!/usr/bin/env sh

# test_exit_code.sh - Test exit code 11 (partial success) handling

# Source test environment
. "$(dirname "$0")/../harness.sh"

echo "Test: Exit code 11 (partial success) handling"
echo "Expected: Process classified as retryable and restarted"
echo ""

# Use partial_success behavior (exits with code 11)
export STUB_BEHAVIOR="partial_success"

start_migration "partial_success"

echo "Initial PID: $MIGRATION_PID"

# Wait for process to exit (stub exits quickly with code 11)
echo "Waiting for process to exit with code 11..."
sleep 3

# Check if process exited
if kill -0 "$MIGRATION_PID" 2>/dev/null; then
    echo "ERROR: Process still running, expected exit"
    kill -KILL "$MIGRATION_PID" 2>/dev/null || true
    exit 1
fi

echo "Process exited"

# Check exit code detection
acct_safe=$(echo "$DST_USER" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g')
if [ -f "$STATE_DIR/${acct_safe}.last_exit" ]; then
    exit_code=$(cat "$STATE_DIR/${acct_safe}.last_exit")
    echo "Detected exit code: $exit_code"

    if [ "$exit_code" = "11" ]; then
        echo "SUCCESS: Exit code 11 correctly detected"
    else
        echo "ERROR: Wrong exit code detected: $exit_code (expected 11)"
        exit 1
    fi
else
    echo "ERROR: Exit code not recorded"
    exit 1
fi

# Check classification
if [ -f "$STATE_DIR/${acct_safe}.last_reason" ]; then
    reason=$(cat "$STATE_DIR/${acct_safe}.last_reason")
    echo "Classification: $reason"

    if [ "$reason" = "retryable" ]; then
        echo "SUCCESS: Correctly classified as retryable"
    else
        echo "ERROR: Wrong classification: $reason (expected retryable)"
        exit 1
    fi
fi

# Wait for restart
if wait_for_restart "$DST_USER" 8; then
    echo "SUCCESS: Process restarted after exit code 11"

    # Check JSON log
    if grep -q '"exit_code":"11"' "$STATE_DIR/watchdog.jsonl" 2>/dev/null; then
        echo "SUCCESS: JSON log contains exit code 11"
    fi

    exit 0
else
    echo "FAILURE: Process not restarted"
    exit 1
fi
