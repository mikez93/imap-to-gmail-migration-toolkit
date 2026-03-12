#!/usr/bin/env sh

# test_sigterm.sh - Test SIGTERM kill detection and restart

# Source test environment
. "$(dirname "$0")/../harness.sh"

echo "Test: SIGTERM kill detection and restart"
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

# Send SIGTERM
echo "Sending SIGTERM to PID $MIGRATION_PID..."
kill -TERM "$MIGRATION_PID"

# Wait for restart (should happen within CHECK_INTERVAL + processing time)
if wait_for_restart "$DST_USER" 8; then
    echo "SUCCESS: Process restarted after SIGTERM"

    # Verify JSON log has restart event
    if grep -q '"event":"restart_triggered"' "$STATE_DIR/watchdog.jsonl" 2>/dev/null; then
        echo "SUCCESS: JSON log contains restart event"
    else
        echo "WARNING: JSON log missing restart event"
    fi

    exit 0
else
    echo "FAILURE: Process did not restart within 8 seconds"
    exit 1
fi