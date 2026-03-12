#!/usr/bin/env sh

# test_sigkill.sh - Test SIGKILL (force kill) detection and restart

# Source test environment
. "$(dirname "$0")/../harness.sh"

echo "Test: SIGKILL force kill detection and restart"
echo "Expected: Process restarts within 5 seconds"
echo ""

# Start a long-running migration
export STUB_BEHAVIOR="default"
start_migration "default"

echo "Initial PID: $MIGRATION_PID"

# Verify it's running
if ! kill -0 "$MIGRATION_PID" 2>/dev/null; then
    echo "ERROR: Migration not running"
    exit 1
fi

# Send SIGKILL (force kill)
echo "Sending SIGKILL to PID $MIGRATION_PID..."
kill -KILL "$MIGRATION_PID"

# Wait for restart (should happen within CHECK_INTERVAL + processing time)
if wait_for_restart "$DST_USER" 8; then
    echo "SUCCESS: Process restarted after SIGKILL"

    # Check exit code detection
    acct_safe=$(echo "$DST_USER" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g')
    if [ -f "$STATE_DIR/${acct_safe}.last_exit" ]; then
        exit_code=$(cat "$STATE_DIR/${acct_safe}.last_exit")
        echo "Detected exit code: $exit_code (expected 137)"
    fi

    exit 0
else
    echo "FAILURE: Process did not restart within 8 seconds"
    exit 1
fi
